#!/usr/bin/env bash

set -o errexit
set +o xtrace
set -o nounset

rippled_image="${RIPPLED_IMAGE:-rippleci/rippled:develop}"
num_keys=${1:-5}
num_services=$num_keys
confs_dir="$PWD/config"
conf_file="rippled.cfg"
validator_hostname="val"
rippled_name="rippled"
network_name="rippled_net"
peer_port=51235
host_rpc_port=5005
host_ws_port=6006
# network variable only _required_ to be defined on macOS. Which you may need to change from "10.0.0" if it conflicts
# with your local network. Furthermore, due to how the explorer is configured, to view rippled with "custom network" set
# to "localhost", rippled will the ports published.
publish="${PUBLISH:-false}"
if [ "$(uname -s)" = "Darwin" ]; then
    publish="true"
fi
if [ "${publish}" = "true" ]; then
    network="${NETWORK:-10.0.0}"
    echo "Publishing ${rippled_name}'s ports ${host_rpc_port} ${host_ws_port} on localhost and all interfaces"
fi

#################################################
# NOTE: The [features] list will need to be     #
# modified to suit the version of rippled used  #
#################################################
set +e
read -r -d '' config_template <<-EOF
[server]
  port_rpc_admin_local
  port_peer
  port_ws_admin_local

[port_rpc_admin_local]
  port = 5005
  ip = 0.0.0.0
  admin = [0.0.0.0]
  protocol = http

[port_peer]
  port = ${peer_port}
  ip = 0.0.0.0
  protocol = peer

[port_ws_admin_local]
  port = 6006
  ip = 0.0.0.0
  admin = [0.0.0.0]
  protocol = ws

[node_db]
  type = NuDB
  path = /var/lib/rippled/db/nudb

[ledger_history]
  full

[database_path]
  /var/lib/rippled/db

[debug_logfile]
  /var/log/rippled/debug.log

[node_size]
  huge

[beta_rpc_api]
  1

[rpc_startup]
  { "command": "log_level", "severity": "debug" }

[features]
  ## New Features
  AMM
  AMMClawback
  CheckCashMakesTrustLine
  Checks
  Clawback
  DeepFreeze
  DeletableAccounts
  DepositAuth
  DepositPreauth
  DID
  DisallowIncoming
  ExpandedSignerList
  Flow
  FlowCross
  FlowSortStrands
  HardenedValidations
  ImmediateOfferKilled
  MultiSignReserve
  NegativeUNL
  NFTokenMintOffer
  NonFungibleTokensV1_1
  PriceOracle
  RequireFullyCanonicalSig
  TicketBatch
  XRPFees

  ## Bug fixes
  fix1513
  fix1515
  fix1543
  fix1571
  fix1578
  fix1623
  fix1781
  fixAmendmentMajorityCalc
  fixAMMOverflowOffer
  fixAMMv1_1
  fixCheckThreading
  fixDisallowIncomingV1
  fixEmptyDID
  fixEnforceNFTokenTrustline
  fixFillOrKill
  fixInnerObjTemplate
  fixInnerObjTemplate2
  fixMasterKeyAsRegularKey
  fixNFTokenPageLinks
  fixNFTokenRemint
  fixNFTokenReserve
  fixNonFungibleTokensV1_2
  fixPayChanRecipientOwnerDir
  fixPreviousTxnID
  fixQualityUpperBound
  fixReducedOffersV1
  fixReducedOffersV2
  fixRemoveNFTokenAutoTrustLine
  fixRmSmallIncreasedQOffers
  fixSTAmountCanonicalize
  fixTakerDryOfferRemoval
  fixTrustLinesToSelf
  fixUniversalNumber


[peer_private]
  0

[ssl_verify]
  0

[compression]
  0

EOF

read -r -d '' healthcheck <<-EOF
    healthcheck:
      test: ["CMD", "/usr/bin/curl", "--insecure", "https://localhost:${peer_port}/health"]
      interval: 5s
EOF

read -r -d '' depends_on <<-EOF
    depends_on:
      ${validator_hostname}0:
        condition: service_healthy
EOF
set +e

if [ -d "${confs_dir}" ]; then
    echo "Cowardly refusing to write in ${confs_dir}!"
    exit 1
elif [ ! -d "${confs_dir}" ]; then
    mkdir -p "${confs_dir}"
fi

generate_token() {
    docker run rippleci/validator_keys_tool | sed '/^[^[]/s/^/  /' > "${conf_dir}/key_${i}"
}

# Start writing the compose file
compose_file="${confs_dir}/docker-compose.yml"
printf "services:" >> "${compose_file}"

for i in $(seq 0 $num_services); do
    if [ $i -lt $num_services ]; then
        node_name="${validator_hostname}${i}"
    else
        node_name="${rippled_name}"
    fi
    nodes+=("${node_name}")
done

set +x
echo "Writing configs..."
for i in $(seq 0 $num_services); do
    node_name=${nodes[$i]}
    signing_support="false"
    if [ "${nodes[$i]}" = "${rippled_name}" ]; then
        signing_support="true"
    fi
    conf_dir="${confs_dir}/${node_name}"
    conf_file_path="${conf_dir}/${conf_file}"
    config_files+=("${conf_file_path}")
    mkdir "${conf_dir}"

    {
        # Write the basic config file to the node's config dir
        # Each validator needs a validator key from the validator-keys-tool
        if [[ ${node_name} =~ ${validator_hostname} ]]; then
            generate_token "${conf_dir}" $i
            printf "%s\n" "$(tail -n+3 "${conf_dir}/key_${i}")"
            pkey_string=$(head -n1 "${conf_dir}/key_${i}")
            pkey=${pkey_string##*" "}
            pkeys+=("${pkey}")
            rm "${conf_dir}/key_${i}"
            printf "\n"
        fi
        printf "%s\n" "${config_template}"
        printf "\n[signing_support]\n  %s\n\n" "${signing_support}"
    } >>  "${conf_file_path}"

    # All nodes get a list of all other nodes except a validator's own
    printf "%s\n" "[ips_fixed]" >> "${conf_file_path}"
    for j in $(seq 0 "$((num_keys - 1))"); do
        if [ $i != $j ]; then
           printf "  %s\n" "${nodes[$j]} ${peer_port}" >> "${conf_file_path}"
        fi
    done
    printf "\n" >> "${conf_file_path}"

    # Write the node's info to the compose file
    entrypoint='"rippled"'
    if [ $i -eq 0 ]; then
        entrypoint="${entrypoint}, \"--start\""
    fi

    compose_file="config/docker-compose.yml"

    {
        printf "\n  %s:\n" "${node_name}"
        printf "    image: %s\n" "${rippled_image}"
        printf "    container_name: %s\n" "${node_name}"
        printf "    hostname: %s\n" "${node_name}"
        printf "    entrypoint: %s\n" "[${entrypoint}]"
        printf "    %s\n" "${healthcheck}" >> "${compose_file}"
        if [ $i != "0" ]; then
            printf "    %s\n" "${depends_on}" >> "${compose_file}"
        fi
        printf "    volumes:\n"
        printf "      - ./%s:/etc/opt/ripple\n" "${node_name}"
        printf "    networks:\n"
        printf "      %s\n" "${network_name}:"
    } >> "${compose_file}"

    node_ip=$((i + 2))
    if [ "${publish}" = "true" ]; then
        printf  "        ipv4_address: %s\n" "${network}.${node_ip}" >> "${compose_file}"
        if [ "${node_name}" = "${rippled_name}" ]; then
            {
                printf "    ports:\n"
                printf "      - 0.0.0.0:%s:5005\n" "${host_rpc_port}"
                printf "      - 0.0.0.0:%s:6006\n" "${host_ws_port}"
            } >> "${compose_file}"
        fi
    fi
done

for config_file in "${config_files[@]}"; do
    printf "[validators]\n" >> "${config_file}"
    for key in "${pkeys[@]}"; do
        printf "  %s\n" "${key}" >> "${config_file}"
    done
done

# Write the network section
printf "\nnetworks:
  %s:
    name: \"%s\"" "${network_name}" "${network_name}" >> "${compose_file}"

if [ "${publish}" == "true" ]; then
    printf "
    #driver: bridge # Should be the default?
    ipam:
      config:
        - subnet: \"%s.0/24\"
          gateway: %s.1\n" "${network}" "${network}" >> "${compose_file}"
fi

# Genesis account
source="rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
secret="snoPBrXtMeMyMHUVTgbuqAfg1SUTb"
set +e
read -r -d '' tx_json <<-EOF
{
    "TransactionType": "Payment",
    "Account": "${source}",
    "Destination": "rh1HPuRVsYYvThxG2Bs1MfjmrVC73S16Fb",
    "Amount": "99999000000000000"
}
EOF
set -e

tx_json=$(echo "${tx_json}" | tr -d "\n" | tr -d " ")

printf "### Fire it up!
docker compose --file config/docker-compose.yml up --detach

### Check how it's going. If it's not ready in about a minute, it probably never will be...
docker exec rippled rippled --silent server_info |
    jq -r '.result.info | {hostid, server_state, complete_ledgers, last_close, uptime}'

### Make a payment of 99999 quintillion drops to rh1HPuRVsYYvThxG2Bs1MfjmrVC73S16Fb
docker exec rippled rippled submit %s '%s'\n" "${secret}" "${tx_json}"
