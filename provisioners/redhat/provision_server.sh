#!/usr/bin/env bash
# variables inbound from provisioner args
# $1 => environment
# $2 => repository
# $3 => gpg key
# $4 => instance


# resources function
function resources() {
    module="${1}"

    cpu_utilization=$(top -bn 1 | awk '{print $9}' | tail -n +8 | awk '{s+=$1} END {print s}')
    if [ "${cpu_utilization%.*}" -gt 80 ]; then
        output_cpu_utilization=$(printf "![cpu %4s]" ${cpu_utilization%.*}%)
    else
        output_cpu_utilization=$(printf " [cpu %4s]" ${cpu_utilization%.*}%)
    fi

    mem_total=$(free --mega | grep "Mem:" | awk '{print $2}')
    mem_usage=$(free --mega | grep "Mem:" | awk '{print $3}')
    mem_utilization=$(free | grep "Mem:" | awk '{print $3/$2 * 100.0}')
    if [ "${mem_utilization%.*}" -gt 80 ]; then
        output_mem_utilization="![mem ${mem_utilization%.*}% ${mem_usage}/${mem_total}MB]"
    else
        output_mem_utilization=" [mem ${mem_utilization%.*}% ${mem_usage}/${mem_total}MB]"
    fi

    swap_total=$(free --mega | grep "Swap:" | awk '{print $2}')
    swap_usage=$(free --mega | grep "Swap:" | awk '{print $3}')
    swap_utilization=$(free | grep "Swap:" | awk '{print $3/$2 * 100.0}')
    output_swap_utilization="[swap ${swap_utilization%.*}% ${swap_usage}/${swap_total}MB]"

    eth0_name=$(cat /proc/net/dev | tail -n +3 | sed -n '1p' | awk '{print $1}')
    eth0_rx=$(cat /proc/net/dev | tail -n +3 | sed -n '1p' | awk '{print $2}' | awk '{ var = $1 / 1024 / 1024 ; print var }')
    eth0_tx=$(cat /proc/net/dev | tail -n +3 | sed -n '1p' | awk '{print $10}' | awk '{ var = $1 / 1024 / 1024 ; print var }')

    eth1_name=$(cat /proc/net/dev | tail -n +3 | sed -n '2p' | awk '{print $1}')
    eth1_rx=$(cat /proc/net/dev | tail -n +3 | sed -n '2p' | awk '{print $2}' | awk '{ var = $1 / 1024 / 1024 ; print var }')
    eth1_tx=$(cat /proc/net/dev | tail -n +3 | sed -n '2p' | awk '{print $10}' | awk '{ var = $1 / 1024 / 1024 ; print var }')

    module_processes_started=$(ls -l /catapult/provisioners/redhat/logs/${module}.*.log 2>/dev/null | wc -l)
    module_processes_complete=$(ls -l /catapult/provisioners/redhat/logs/${module}.*.complete 2>/dev/null | wc -l)
    module_processes_active=$(( $module_processes_started - $module_processes_complete ))
    if [ "${module_processes_active}" -gt 4 ]; then
        output_module_processes="![$(printf "%-2s" ${module_processes_active}) active - $(printf "%-2s" ${module_processes_complete}) complete]"
    else
        output_module_processes=" [$(printf "%-2s" ${module_processes_active}) active - $(printf "%-2s" ${module_processes_complete}) complete]"
    fi

    echo -e " \
> managing parallel processes \
${output_module_processes} \
${output_cpu_utilization} \
${output_mem_utilization} \
${output_swap_utilization} \
[${eth0_name//:} ${eth0_rx%.*}rx:${eth0_tx%.*}tx MB] \
[${eth1_name//:} ${eth1_rx%.*}rx:${eth1_tx%.*}tx MB] \
    "
}

# install shyaml
yum install python -y
yum install python-pip -y
sudo pip install pathlib --trusted-host pypi.python.org --upgrade
sudo pip install pyyaml==5.4.1 --trusted-host pypi.python.org
sudo pip install shyaml==0.6.2 --trusted-host pypi.python.org

# run server provision
if [ $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-values-0 redhat.servers.$4.modules) ]; then
    provisionstart=$(date +%s)
    echo -e "\n\n\n==> PROVISION: ${4}"

    # decrypt secrets
    gpg --verbose --batch --yes --passphrase ${3} --output /catapult/secrets/configuration.yml --decrypt /catapult/secrets/configuration.yml.gpg
    if [ $? -eq 0 ]; then
        chmod 700 /catapult/secrets/configuration.yml
    else
        echo -e "Cannot decrypt /catapult/secrets/configuration.yml, please check the gpg key."
        exit 1
    fi
    gpg --verbose --batch --yes --passphrase ${3} --output /catapult/secrets/id_rsa --decrypt /catapult/secrets/id_rsa.gpg
    if [ $? -eq 0 ]; then
        chmod 700 /catapult/secrets/id_rsa
    else
        echo -e "Cannot decrypt /catapult/secrets/id_rsa, please check the gpg key."
        exit 1
    fi
    gpg --verbose --batch --yes --passphrase ${3} --output /catapult/secrets/id_rsa.pub --decrypt /catapult/secrets/id_rsa.pub.gpg
    if [ $? -eq 0 ]; then
        chmod 700 /catapult/secrets/id_rsa.pub
    else
        echo -e "Cannot decrypt /catapult/secrets/id_rsa.pub, please check the gpg key."
        exit 1
    fi

    # get configuration
    source "/catapult/provisioners/redhat/modules/catapult.sh"

    # report the start of this deployment to new relic
    newrelic_deployment=$(curl --silent --show-error --connect-timeout 10 --max-time 20 --write-out "HTTPSTATUS:%{http_code}" --request POST "https://api.newrelic.com/deployments.xml" \
    --header "X-Api-Key: $(catapult company.newrelic_api_key)" \
    --data "deployment[app_name]=$(catapult company.name | tr '[:upper:]' '[:lower:]')-${1}-redhat" \
    --data "deployment[description]=Catapult Provision Started" \
    --data "deployment[revision]=$(cat "/catapult/VERSION.yml" | shyaml get-value version)")
    newrelic_deployment_status=$(echo "${newrelic_deployment}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    newrelic_deployment=$(echo "${newrelic_deployment}" | sed -e 's/HTTPSTATUS\:.*//g')
    # check for a curl error
    if [ $newrelic_deployment_status == 000 ]; then
        echo -e "==> REPORTED TO NEW RELIC: ERROR"
    else
        echo -e "==> REPORTED TO NEW RELIC: YES"
    fi

    # loop through each required module
    cat "/catapult/provisioners/provisioners.yml" | shyaml get-values-0 redhat.servers.$4.modules |
    while read -r -d $'\0' module; do

        # check for reboot status between modules
        # not required for red hat to properly install and update software
        kernel_running=$(uname --release)
        kernel_running="kernel-${kernel_running}"
        kernel_staged=$(rpm --last --query kernel | head --lines 1 | awk '{print $1}')
        if [ "${kernel_running}" != "${kernel_staged}" ]; then
            echo -e "\n\n\n==> REBOOT REQUIRED STATUS: [RECOMMENDED] Red Hat kernel requires a reboot of this machine. The current running kernal is ${kernel_running} and the staged kernel is ${kernel_staged}."
            if [ $1 = "dev" ]; then
                echo -e "\n> Please run this command: vagrant reload <machine-name> --provision"
                # require a reboot in dev only
                exit 1
            fi
        else
            echo -e "\n\n\n==> REBOOT REQUIRED STATUS: [NOT REQUIRED] Continuing..."
        fi

        # start the module
        start=$(date +%s)
        echo -e "==> MODULE: ${module}"
        echo -e "==> DESCRIPTION: $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.description)"
        echo -e "==> MULTITHREADING: $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.multithreading)"
        echo -e "==> PERSISTENCE: $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.persistent)"
        echo -e "==> MULTITHREADING PERSISTENCE: $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.multithreading_persistent)"

        # if there are no catpult updates and the module is not persistent, skip
        if ([ ! -f "/catapult/provisioners/redhat/logs/catapult.changes" ] && [ $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.persistent) == "False" ]); then
            echo "> module skipped when there are no catapult repository changes..."
        # invoke multithreading module in parallel
        elif ([ $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.multithreading) == "True" ]); then
            # enable job control
            set -m
            # create a website index to pass to each sub-process
            website_index=0
            # loop through websites and start sub-processes
            while read -r -d $'\0' website; do
                # determine if we need to skip modules
                idle=$(echo "${website}" | shyaml get-value idle 2>/dev/null )
                if ([ "${idle}" = "True" ]) && ([ $1 = "dev" ] || [ $1 = "test" ]); then
                    echo "> skipping module, website is set to idle..." > "/catapult/provisioners/redhat/logs/${module}.$(echo "${website}" | shyaml get-value domain).log"
                    touch "/catapult/provisioners/redhat/logs/${module}.$(echo "${website}" | shyaml get-value domain).complete"
                elif ([ ! -f "/catapult/provisioners/redhat/logs/catapult.changes" ] && [ $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.multithreading_persistent) != "True" ] && [ ! -f "/catapult/provisioners/redhat/logs/domain.$(echo "${website}" | shyaml get-value domain).changes" ]); then
                    echo "> skipping module, there are no catapult or website repository changes..." > "/catapult/provisioners/redhat/logs/${module}.$(echo "${website}" | shyaml get-value domain).log"
                    touch "/catapult/provisioners/redhat/logs/${module}.$(echo "${website}" | shyaml get-value domain).complete"
                # if there are incoming websites changes, run the persistent module for this domain
                else
                    # only allow a certain number of parallel bash sub-processes at once
                    while true; do
                        resources=$(resources ${module})
                        if ([[ $resources == *"!"* ]]); then
                            echo "${resources}"
                            sleep 0.25
                        else
                            echo "${resources}"
                            break
                        fi
                    done
                    bash "/catapult/provisioners/redhat/modules/${module}.sh" $1 $2 $3 $4 $website_index > "/catapult/provisioners/redhat/logs/${module}.$(echo "${website}" | shyaml get-value domain).log" 2>&1 &
                fi
                (( website_index += 1 ))
            done < <(echo "${configuration}" | shyaml get-values-0 websites.apache)
            # loop through websites and look for finished sub-process
            while read -r -d $'\0' website; do
                domain=$(echo "${website}" | shyaml get-value domain)
                domain_tld_override=$(echo "${website}" | shyaml get-value domain_tld_override 2>/dev/null )
                software=$(echo "${website}" | shyaml get-value software 2>/dev/null )
                software_auto_update=$(echo "${website}" | shyaml get-value software_auto_update 2>/dev/null )
                software_dbprefix=$(echo "${website}" | shyaml get-value software_dbprefix 2>/dev/null )
                software_workflow=$(echo "${website}" | shyaml get-value software_workflow 2>/dev/null )
                # if there are no incoming catapult changes, website changes, and there is no need to run persistent modules for this domain
                if ([ ! -f "/catapult/provisioners/redhat/logs/catapult.changes" ] && [ $(cat "/catapult/provisioners/provisioners.yml" | shyaml get-value redhat.modules.${module}.multithreading_persistent) != "True" ] && [ ! -f "/catapult/provisioners/redhat/logs/domain.$(echo "${website}" | shyaml get-value domain).changes" ]); then
                    : #no-op
                # if there are incoming websites changes, run the persistent module for this domain
                else
                    # only allow a certain number of parallel bash sub-processes at once
                    while true; do
                        resources=$(resources ${module})
                        if [ ! -e "/catapult/provisioners/redhat/logs/${module}.${domain}.complete" ]; then
                            echo "${resources}"
                            sleep 0.25
                        else
                            break
                        fi
                    done
                fi
                echo -e "========================================================="
                echo -e "=> environment: ${1}"
                echo -e "=> domain: ${domain}"
                echo -e "=> domain_tld_override: ${domain_tld_override}"
                echo -e "=> software: ${software}"
                echo -e "=> software_auto_update: ${software_auto_update}"
                echo -e "=> software_dbprefix: ${software_dbprefix}"
                echo -e "=> software_workflow: ${software_workflow}"
                # output status of catapult changes
                if [ -f "/catapult/provisioners/redhat/logs/catapult.changes" ]; then
                    echo -e "=> catapult_changes: yes"
                else
                    echo -e "=> catapult_changes: no"
                fi
                # output status of website changes
                if [ -f "/catapult/provisioners/redhat/logs/domain.$(echo "${website}" | shyaml get-value domain).changes"  ]; then
                    echo -e "=> website_changes: yes"
                else
                    echo -e "=> website_changes: no"
                fi
                cat "/catapult/provisioners/redhat/logs/${module}.${domain}.log"
                echo -e "========================================================="
            done < <(echo "${configuration}" | shyaml get-values-0 websites.apache)
        # invoke standard module in series
        else
            bash "/catapult/provisioners/redhat/modules/${module}.sh" $1 $2 $3 $4
        fi

        end=$(date +%s)
        echo -e "==> MODULE: ${module}"
        echo -e "==> DURATION: $(($end - $start)) seconds"
    done

    # remove secrets
    if [ "${1}" != "dev" ]; then
        sudo rm /catapult/secrets/configuration.yml
        sudo rm /catapult/secrets/id_rsa
        sudo rm /catapult/secrets/id_rsa.pub
    fi
    if [ -f /catapult/provisioners/redhat/installers/temp/${1}.cnf ]; then
        sudo rm /catapult/provisioners/redhat/installers/temp/${1}.cnf
    fi

    provisionend=$(date +%s)
    provisiontotal=$(date -d@$(($provisionend - $provisionstart)) -u +%H:%M:%S)
    echo -e "\n\n\n==> PROVISION: ${4}"
    echo -e "==> FINISH: $(date)" | tee -a /catapult/provisioners/redhat/logs/$4.log
    echo -e "==> DURATION: ${provisiontotal} total time" | tee -a /catapult/provisioners/redhat/logs/$4.log

    # report the end of this deployment to new relic
    newrelic_deployment=$(curl --silent --show-error --connect-timeout 10 --max-time 20 --write-out "HTTPSTATUS:%{http_code}" --request POST "https://api.newrelic.com/deployments.xml" \
    --header "X-Api-Key: $(catapult company.newrelic_api_key)" \
    --data "deployment[app_name]=$(catapult company.name | tr '[:upper:]' '[:lower:]')-${1}-redhat" \
    --data "deployment[description]=Catapult Provision Ended" \
    --data "deployment[revision]=$(cat "/catapult/VERSION.yml" | shyaml get-value version)")
    newrelic_deployment_status=$(echo "${newrelic_deployment}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    newrelic_deployment=$(echo "${newrelic_deployment}" | sed -e 's/HTTPSTATUS\:.*//g')
    # check for a curl error
    if [ $newrelic_deployment_status == 000 ]; then
        echo -e "==> REPORTED TO NEW RELIC: ERROR"
    else
        echo -e "==> REPORTED TO NEW RELIC: YES"
    fi

else
    echo -e "Error: Cannot detect the server type."
    exit 1
fi
