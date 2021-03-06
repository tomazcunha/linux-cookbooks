#!/bin/bash -e

source "$(dirname "${BASH_SOURCE[0]}")/util.bash"

##############################
# AUTO SCALE GROUP UTILITIES #
##############################

function getAutoScaleGroupNameByStackName()
{
    local -r stackName="${1}"

    checkNonEmptyString "${stackName}" 'undefined stack name'

    aws autoscaling describe-auto-scaling-groups \
        --output 'json' |
    jq \
        --arg jqStackName "${stackName}" \
        --compact-output \
        --raw-output \
        --sort-keys \
        '.["AutoScalingGroups"] |
        .[] |
        .["Tags"] |
        .[] |
        select(.["ResourceType"] == "auto-scaling-group") |
        select(.["Key"] == "aws:cloudformation:stack-name") |
        select(.["Value"] == $jqStackName) |
        .["ResourceId"] // empty'
}

#############################
# CLOUD-FORMATION UTILITIES #
#############################

function getStackIDByName()
{
    local -r stackName="${1}"

    checkNonEmptyString "${stackName}" 'undefined stack name'

    aws cloudformation describe-stacks \
        --output 'text' \
        --query 'Stacks[*].[StackId]' \
        --stack-name "${stackName}" \
    2> '/dev/null' || true
}

#################
# EC2 UTILITIES #
#################

function associateElasticPublicIPWithInstanceID()
{
    local -r elasticPublicIP="${1}"
    local -r instanceID="${2}"
    local region="${3}"

    # Set Default Value

    if [[ "$(isEmptyString "${region}")" = 'true' ]]
    then
        region="$(getInstanceRegion 'false')"
    fi

    # Validate Values

    checkNonEmptyString "${elasticPublicIP}" 'undefined elastic public ip'
    checkNonEmptyString "${instanceID}" 'undefined instance id'

    # Associate Elastic Public IP

    local -r allocationID="$(getEC2ElasticAllocationIDByElasticPublicIP "${elasticPublicIP}" "${region}")"

    checkNonEmptyString "${allocationID}" 'undefined allocation id'

    aws ec2 associate-address \
        --allocation-id "${allocationID}" \
        --allow-reassociation \
        --instance-id "${instanceID}" \
        --region "${region}"
}

function associateElasticPublicIPWithThisInstanceID()
{
    local -r elasticPublicIP="${1}"

    associateElasticPublicIPWithInstanceID "${elasticPublicIP}" "$(getInstanceID 'false')"
}

function getEC2ElasticAllocationIDByElasticPublicIP()
{
    local -r elasticPublicIP="${1}"
    local region="${3}"

    # Set Default Value

    if [[ "$(isEmptyString "${region}")" = 'true' ]]
    then
        region="$(getInstanceRegion 'false')"
    fi

    checkNonEmptyString "${elasticPublicIP}" 'undefined elastic public ip'

    # Get EC2 Elastic Allocation ID

    aws ec2 describe-addresses \
        --output 'text' \
        --public-ips "${elasticPublicIP}" \
        --query 'Addresses[0].[AllocationId]' \
        --region "${region}" \
    2> '/dev/null'
}

function getEC2PrivateIpAddressByInstanceID()
{
    local -r instanceID="${1}"
    local region="${2}"

    # Set Default Value

    if [[ "$(isEmptyString "${region}")" = 'true' ]]
    then
        region="$(getInstanceRegion 'false')"
    fi

    # Get Private IP

    if [[ "$(isEmptyString "${instanceID}")" = 'true' ]]
    then
        curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/local-ipv4'
    else
        aws ec2 describe-instances \
            --instance-id "${instanceID}" \
            --output 'text' \
            --query 'Reservations[*].Instances[*].PrivateIpAddress' \
            --region "${region}"
    fi
}

function getEC2PrivateIpAddresses()
{
    local namePattern="${1}"
    local excludeCurrentInstance="${2}"
    local vpcID="${3}"
    local region="${4}"

    # Set Default Values

    if [[ "$(isEmptyString "${namePattern}")" = 'true' ]]
    then
        namePattern='*'
    fi

    if [[ "${excludeCurrentInstance}" != 'true' ]]
    then
        excludeCurrentInstance='false'
    fi

    if [[ "$(isEmptyString "${vpcID}")" = 'true' ]]
    then
        vpcID="$(getInstanceVPCID)"
    fi

    if [[ "$(isEmptyString "${region}")" = 'true' ]]
    then
        region="$(getInstanceRegion 'false')"
    fi

    # Get Instances

    local -r instances=($(
        aws ec2 describe-instances \
            --filters \
                'Name=instance-state-name,Values=pending,running' \
                "Name=tag:Name,Values=${namePattern}" \
                "Name=vpc-id,Values=${vpcID}" \
            --output 'text' \
            --query 'Reservations[*].Instances[*].PrivateIpAddress' \
            --region "${region}"
    ))

    if [[ "${excludeCurrentInstance}" = 'true' ]]
    then
        excludeElementFromArray "$(getEC2PrivateIpAddressByInstanceID '' '')" "${instances[@]}"
    else
        echo "${instances[@]}"
    fi
}

function getKeyPairFingerPrintByName()
{
    local -r keyPairName="${1}"

    checkNonEmptyString "${keyPairName}" 'undefined key pair name'

    aws ec2 describe-key-pairs \
        --key-name "${keyPairName}" \
        --output 'text' \
        --query 'KeyPairs[0].[KeyFingerprint]' \
    2> '/dev/null' |
    grep -E -v '^None$'
}

function getLatestAMIIDByAMINamePattern()
{
    local -r amiIsPublic="${1}"
    local -r amiNamePattern="${2}"

    checkNonEmptyString "${amiIsPublic}" 'undefined ami is public'
    checkNonEmptyString "${amiNamePattern}" 'undefined ami name pattern'

    aws ec2 describe-images \
        --filters \
            'Name=architecture,Values=x86_64' \
            'Name=image-type,Values=machine' \
            "Name=is-public,Values=${amiIsPublic}" \
            "Name=name,Values=${amiNamePattern}" \
            'Name=state,Values=available' \
        --output 'text' \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' |
    grep -E -v '^None$'
}

function getSecurityGroupIDByName()
{
    local -r securityGroupName="${1}"

    checkNonEmptyString "${securityGroupName}" 'undefined security group name'

    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${securityGroupName}" \
        --output 'text' \
        --query 'SecurityGroups[0].[GroupId]' |
    grep -E -v '^None$'
}

function getSecurityGroupIDsByNames()
{
    local -r securityGroupNames=("${@}")

    local securityGroupIDs=''
    local securityGroupName=''

    for securityGroupName in "${securityGroupNames[@]}"
    do
        local securityGroupID=''
        securityGroupID="$(getSecurityGroupIDByName "${securityGroupName}")"

        checkNonEmptyString "${securityGroupID}" "security group name '${securityGroupName}' not found"

        securityGroupIDs="$(printf '%s\n%s' "${securityGroupIDs}" "${securityGroupID}")"
    done

    echo "${securityGroupIDs}"
}

function revokeSecurityGroupEgress()
{
    local -r securityGroupID="${1}"
    local -r securityGroupName="${2}"

    checkNonEmptyString "${securityGroupID}" 'undefined security group ID'
    checkNonEmptyString "${securityGroupName}" 'undefined security group name'

    local -r ipPermissionsEgress="$(
        aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${securityGroupName}" \
            --output 'json' \
            --query 'SecurityGroups[0].[IpPermissionsEgress][0]'
    )"

    if [[ "$(isEmptyString "${ipPermissionsEgress}")" = 'false' && "${ipPermissionsEgress}" != '[]' ]]
    then
        aws ec2 revoke-security-group-egress \
            --group-id "${securityGroupID}" \
            --ip-permissions "${ipPermissionsEgress}"
    fi
}

function revokeSecurityGroupIngress()
{
    local -r securityGroupID="${1}"
    local -r securityGroupName="${2}"

    checkNonEmptyString "${securityGroupID}" 'undefined security group ID'
    checkNonEmptyString "${securityGroupName}" 'undefined security group name'

    local -r ipPermissions="$(
        aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${securityGroupName}" \
            --output 'json' \
            --query 'SecurityGroups[0].[IpPermissions][0]'
    )"

    if [[ "$(isEmptyString "${ipPermissions}")" = 'false' && "${ipPermissions}" != '[]' ]]
    then
        aws ec2 revoke-security-group-ingress \
            --group-id "${securityGroupID}" \
            --ip-permissions "${ipPermissions}"
    fi
}

function updateInstanceName()
{
    local -r instanceName="${1}"

    header 'UPDATING INSTANCE NAME'

    checkNonEmptyString "${instanceName}" 'undefined instance name'

    info "${instanceName}"

    aws ec2 create-tags \
        --region "$(getInstanceRegion 'false')" \
        --resources "$(getInstanceID 'false')" \
        --tags "Key='Name',Value='${instanceName}'"
}

#####################
# GENERAL UTILITIES #
#####################

function checkValidRegion()
{
    local -r region="${1}"

    if [[ "$(isValidRegion "${region}")" = 'false' ]]
    then
        fatal "\nFATAL : invalid region '${region}'"
    fi
}

function getAllowedRegions()
{
    echo 'ap-east-1 ap-northeast-1 ap-northeast-2 ap-south-1 ap-southeast-1 ap-southeast-2 ca-central-1 eu-central-1 eu-north-1 eu-west-1 eu-west-2 eu-west-3 me-south-1 sa-east-1 us-east-1 us-east-2 us-west-1 us-west-2'
}

function getRegionFromRecordSetAliasTargetDNSName()
{
    local -r recordSetAliasTargetDNSName="${1}"

    # Regions

    local -r allowedRegions=($(getAllowedRegions))
    local region=''

    for region in "${allowedRegions[@]}"
    do
        if [[ "$(grep -F -i -o "${region}" <<< "${recordSetAliasTargetDNSName}")" != '' ]]
        then
            echo "${region}" && return 0
        fi
    done
}

function getShortRegionName()
{
    local -r region="${1}"

    checkValidRegion "${region}"

    if [[ "${region}" = 'ap-east-1' ]]
    then
        echo 'ape1'
    elif [[ "${region}" = 'ap-northeast-1' ]]
    then
        echo 'apne1'
    elif [[ "${region}" = 'ap-northeast-2' ]]
    then
        echo 'apne2'
    elif [[ "${region}" = 'ap-south-1' ]]
    then
        echo 'aps1'
    elif [[ "${region}" = 'ap-southeast-1' ]]
    then
        echo 'apse1'
    elif [[ "${region}" = 'ap-southeast-2' ]]
    then
        echo 'apse2'
    elif [[ "${region}" = 'ca-central-1' ]]
    then
        echo 'cac1'
    elif [[ "${region}" = 'eu-central-1' ]]
    then
        echo 'euc1'
    elif [[ "${region}" = 'eu-north-1' ]]
    then
        echo 'eun1'
    elif [[ "${region}" = 'eu-west-1' ]]
    then
        echo 'euw1'
    elif [[ "${region}" = 'eu-west-2' ]]
    then
        echo 'euw2'
    elif [[ "${region}" = 'eu-west-3' ]]
    then
        echo 'euw3'
    elif [[ "${region}" = 'me-south-1' ]]
    then
        echo 'mes1'
    elif [[ "${region}" = 'sa-east-1' ]]
    then
        echo 'sae1'
    elif [[ "${region}" = 'us-east-1' ]]
    then
        echo 'use1'
    elif [[ "${region}" = 'us-east-2' ]]
    then
        echo 'use2'
    elif [[ "${region}" = 'us-west-1' ]]
    then
        echo 'usw1'
    elif [[ "${region}" = 'us-west-2' ]]
    then
        echo 'usw2'
    fi
}

function isValidRegion()
{
    local -r region="${1}"

    local -r allowedRegions=($(getAllowedRegions))

    isElementInArray "${region}" "${allowedRegions[@]}"
}

function unzipAWSS3RemoteFile()
{
    local -r downloadURL="${1}"
    local -r installFolder="${2}"
    local extension="${3}"

    # Find Extension

    local exExtension=''

    if [[ "$(isEmptyString "${extension}")" = 'true' ]]
    then
        extension="$(getFileExtension "${downloadURL}")"
        exExtension="$(rev <<< "${downloadURL}" | cut -d '.' -f 1-2 | rev)"
    fi

    # Unzip

    if [[ "$(grep -i '^tgz$' <<< "${extension}")" != '' || "$(grep -i '^tar\.gz$' <<< "${extension}")" != '' || "$(grep -i '^tar\.gz$' <<< "${exExtension}")" != '' ]]
    then
        debug "Downloading '${downloadURL}'\n"

        aws s3 cp "${downloadURL}" - | tar -C "${installFolder}" -x -z --strip 1 ||
        fatal "\nFATAL : '${downloadURL}' does not exist or authentication failed"
    else
        fatal "\nFATAL : file extension '${extension}' not supported"
    fi
}

#################
# IAM UTILITIES #
#################

function existRole()
{
    local -r roleName="${1}"

    invertTrueFalseString "$(isEmptyString "$(aws iam get-role --role-name "${roleName}" 2> '/dev/null')")"
}

###########################
# INSTANCE DATA UTILITIES #
###########################

function getInstanceAvailabilityZone()
{
    curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/placement/availability-zone'
}

function getInstanceIAMRole()
{
    curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/iam/info' |
    jq \
        --compact-output \
        --raw-output \
        --sort-keys \
        '.["InstanceProfileArn"] // empty' |
    cut -d '/' -f 2
}

function getInstanceID()
{
    local -r idOnly="${1}"

    local -r fullInstanceID="$(curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/instance-id')"

    if [[ "${idOnly}" = 'true' ]]
    then
        cut -d '-' -f 2 <<< "${fullInstanceID}"
    else
        echo "${fullInstanceID}"
    fi
}

function getInstanceMACAddress()
{
    curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/mac'
}

function getInstancePublicIPV4()
{
    curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/meta-data/public-ipv4'
}

function getInstanceRegion()
{
    local -r shortVersion="${1}"

    local -r availabilityZone="$(getInstanceAvailabilityZone)"

    checkNonEmptyString "${availabilityZone}" 'undefined availabilityZone'

    local -r fullRegionName="${availabilityZone:0:${#availabilityZone} - 1}"

    if [[ "${shortVersion}" = 'true' ]]
    then
        getShortRegionName "${fullRegionName}"
    else
        echo "${fullRegionName}"
    fi
}

function getInstanceSubnetID()
{
    curl -s --retry 12 --retry-delay 5 "http://instance-data/latest/meta-data/network/interfaces/macs/$(getInstanceMACAddress)/subnet-id"
}

function getInstanceUserDataValue()
{
    local -r key="$(escapeGrepSearchPattern "${1}")"

    trimString "$(
        curl -s --retry 12 --retry-delay 5 'http://instance-data/latest/user-data' |
        grep -E -o "^\s*${key}\s*=\s*.*$" |
        tail -1 |
        awk -F '=' '{ print $2 }'
    )"
}

function getInstanceVPCID()
{
    curl -s --retry 12 --retry-delay 5 "http://instance-data/latest/meta-data/network/interfaces/macs/$(getInstanceMACAddress)/vpc-id"
}

###########################
# LOAD BALANCER UTILITIES #
###########################

function getAWSELBAccountID()
{
    local -r region="${1}"

    checkValidRegion "${region}"

    if [[ "${region}" = 'ap-east-1' ]]
    then
        echo '754344448648'
    elif [[ "${region}" = 'ap-northeast-1' ]]
    then
        echo '582318560864'
    elif [[ "${region}" = 'ap-northeast-2' ]]
    then
        echo '600734575887'
    elif [[ "${region}" = 'ap-northeast-3' ]]
    then
        echo '383597477331'
    elif [[ "${region}" = 'ap-south-1' ]]
    then
        echo '718504428378'
    elif [[ "${region}" = 'ap-southeast-1' ]]
    then
        echo '114774131450'
    elif [[ "${region}" = 'ap-southeast-2' ]]
    then
        echo '783225319266'
    elif [[ "${region}" = 'ca-central-1' ]]
    then
        echo '985666609251'
    elif [[ "${region}" = 'cn-north-1' ]]
    then
        echo '638102146993'
    elif [[ "${region}" = 'cn-northwest-1' ]]
    then
        echo '037604701340'
    elif [[ "${region}" = 'eu-central-1' ]]
    then
        echo '054676820928'
    elif [[ "${region}" = 'eu-north-1' ]]
    then
        echo '897822967062'
    elif [[ "${region}" = 'eu-west-1' ]]
    then
        echo '156460612806'
    elif [[ "${region}" = 'eu-west-2' ]]
    then
        echo '652711504416'
    elif [[ "${region}" = 'eu-west-3' ]]
    then
        echo '009996457667'
    elif [[ "${region}" = 'me-south-1' ]]
    then
        echo '076674570225'
    elif [[ "${region}" = 'sa-east-1' ]]
    then
        echo '507241528517'
    elif [[ "${region}" = 'us-east-1' ]]
    then
        echo '127311923021'
    elif [[ "${region}" = 'us-east-2' ]]
    then
        echo '033677994240'
    elif [[ "${region}" = 'us-gov-east-1' ]]
    then
        echo '190560391635'
    elif [[ "${region}" = 'us-gov-west-1' ]]
    then
        echo '048591011584'
    elif [[ "${region}" = 'us-west-1' ]]
    then
        echo '027434742980'
    elif [[ "${region}" = 'us-west-2' ]]
    then
        echo '797873946194'
    fi
}

function getLoadBalancerDNSNameByName()
{
    local -r loadBalancerName="${1}"

    checkNonEmptyString "${loadBalancerName}" 'undefined load balancer name'

    aws elb describe-load-balancers \
        --load-balancer-name "${loadBalancerName}" \
        --output 'text' \
        --query 'LoadBalancerDescriptions[*].DNSName'
}

function isLoadBalancerFromStackName()
{
    local -r loadBalancerName="${1}"
    local -r stackName="${2}"

    checkNonEmptyString "${loadBalancerName}" 'undefined load balancer name'
    checkNonEmptyString "${stackName}" 'undefined stack name'

    local -r loadBalancerStackName="$(
        aws elb describe-tags \
            --load-balancer-name "${loadBalancerName}" |
        jq \
            --arg jqStackName "${stackName}" \
            --compact-output \
            --raw-output \
            --sort-keys \
            '.["TagDescriptions"] |
            .[] |
            .["Tags"] |
            .[] |
            select(.["Key"] == "aws:cloudformation:stack-name") |
            select(.["Value"] == $jqStackName) // empty'
    )"

    if [[ "$(isEmptyString "${loadBalancerStackName}")" = 'false' ]]
    then
        echo 'true' && return 0
    fi

    echo 'false' && return 1
}

function getLoadBalancerTag()
{
    local -r tags="${1}"
    local -r key="${2}"

    jq \
        --arg jqKey "${key}" \
        --compact-output \
        --raw-output \
        --sort-keys \
        '.["TagDescriptions"][] |
        .["Tags"] |
        map(select(.["Key"] == $jqKey))[] |
        .["Value"] // empty' \
    <<< "${tags}"
}

function getLoadBalancerTags()
{
    local -r loadBalancerName="${1}"

    checkNonEmptyString "${loadBalancerName}" 'undefined load balancer name'

    aws elb describe-tags \
        --output 'json' \
        --load-balancer-name "${loadBalancerName}"
}

######################
# ROUTE-53 UTILITIES #
######################

function getHostedZoneIDByDomainName()
{
    local -r hostedZoneDomainName="${1}"

    checkNonEmptyString "${hostedZoneDomainName}" 'undefined hosted zone domain name'

    aws route53 list-hosted-zones-by-name \
        --dns-name "${hostedZoneDomainName}" \
        --output 'text' \
        --query 'HostedZones[0].[Id]' |
    grep -E -v '^None$' |
    awk -F '/' '{ print $3 }'
}

################
# S3 UTILITIES #
################

function existS3Bucket()
{
    local -r bucketName="${1}"

    isEmptyString "$(aws s3api head-bucket --bucket "${bucketName}" 2>&1)"
}

#################
# STS UTILITIES #
#################

function getAWSAccountID()
{
    aws sts get-caller-identity \
        --output 'text' \
        --query 'Account'
}

#################
# VPC UTILITIES #
#################

function getAvailabilityZonesByVPCName()
{
    local -r vpcName="${1}"

    checkNonEmptyString "${vpcName}" 'undefined VPC name'

    local -r vpcID="$(getVPCIDByName "${vpcName}")"

    checkNonEmptyString "${vpcID}" 'undefined VPC ID'

    aws ec2 describe-subnets \
        --filters \
            'Name=state,Values=available' \
            "Name=vpc-id,Values=${vpcID}" \
        --query 'Subnets[*].AvailabilityZone' |
    jq \
        --compact-output \
        --raw-output \
        'unique |
        .[] // empty'
}

function getCurrentVPCCIDRBlock()
{
    curl -s --retry 12 --retry-delay 5 "http://instance-data/latest/meta-data/network/interfaces/macs/$(getInstanceMACAddress)/vpc-ipv4-cidr-block"
}

function getIPV4CIDRByVPCName()
{
    local -r vpcName="${1}"

    checkNonEmptyString "${vpcName}" 'undefined VPC name'

    aws ec2 describe-vpcs \
        --filter "Name=tag:Name,Values=${vpcName}" \
        --output 'text' \
        --query 'Vpcs[0].CidrBlock' |
    grep -E -v '^None$'
}

function getPublicElasticIPs()
{
    aws ec2 describe-addresses \
        --output 'text' \
        --query 'sort_by(Addresses, &PublicIp)[*].[PublicIp]'
}

function getSubnetIDByName()
{
    local -r vpcName="${1}"
    local -r subnetName="${2}"

    local -r vpcID="$(getVPCIDByName "${vpcName}")"

    checkNonEmptyString "${vpcID}" 'undefined VPC ID'

    aws ec2 describe-subnets \
        --filter \
            "Name=tag:Name,Values=${subnetName}" \
            "Name=vpc-id,Values=${vpcID}" \
        --output 'text' \
        --query 'Subnets[0].[SubnetId]' |
    grep -E -v '^None$'
}

function getSubnetIDsByNames()
{
    local -r vpcName="${1}"
    local -r subnetNames=("${@:2}")

    local subnetIDs=''
    local subnetName=''

    for subnetName in "${subnetNames[@]}"
    do
        local subnetID=''
        subnetID="$(getSubnetIDByName "${vpcName}" "${subnetName}")"

        checkNonEmptyString "${subnetID}" "subnet name '${subnetName}' not found"

        subnetIDs="$(printf '%s\n%s' "${subnetIDs}" "${subnetID}")"
    done

    echo "${subnetIDs}"
}

function getVPCIDByName()
{
    local -r vpcName="${1}"

    checkNonEmptyString "${vpcName}" 'undefined VPC name'

    aws ec2 describe-vpcs \
        --filter "Name=tag:Name,Values=${vpcName}" \
        --output 'text' \
        --query 'Vpcs[0].[VpcId]' |
    grep -E -v '^None$'
}