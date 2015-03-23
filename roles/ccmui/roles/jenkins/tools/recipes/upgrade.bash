#!/bin/bash -e

function main()
{
    local appPath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local command="sudo apt-get update -m &&
                   sudo apt-get upgrade --force-yes -m -y &&
                   sudo apt-get dist-upgrade --force-yes -m -y &&
                   sudo apt-get autoremove -y"

    "${appPath}/../../../../../../tools/run-remote-command.bash" \
        --attribute-file "${appPath}/../attributes/jenkins.bash" \
        --command "${command}" \
        --machine-type 'master-slave'
}

main "${@}"