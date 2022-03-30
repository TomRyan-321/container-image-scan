#!/bin/bash
: <<'#DESCRIPTION#'
File: cs_scanimage.sh
Description: Bash script to tag push and scan container images via the CrowdStrike Image Scan registry and output the full JSON report.
#DESCRIPTION#

usage() 
{
    echo "usage: 
$0 \\
    -u | --clientid <FALCONCLIENTID> \\
    -s | --clientsecret <FALCONCLIENTSECRET> \\
    -f | --region <FALCONREGION> \\
    -r | --repo <REPOSITORY> \\
    -t | --tag <IMAGETAG> \\
    -p | --podman || Use the Podman runtime instead of Docker \\
    -h | --help display this help message"
    exit 2
}

while (( "$#" )); do
case "$1" in
    -u|--clientid)
    if [[ -n ${2:-} ]] ; then
        CS_CLIENT_ID="$2"
        shift
    fi
    ;;
    -s|--clientsecret)
    if [[ -n ${2:-} ]]; then
        CS_CLIENT_SECRET="$2"
        shift
    fi
    ;;
    -f|--region)
    if [[ -n ${2:-} ]]; then
        CS_REGION="$2"
        shift
    fi
    ;;
    -r|--repo)
    if [[ -n ${2:-} ]]; then
        REPO="$2"
        shift
    fi
    ;;
    -t|--tag)
    if [[ -n ${1} ]]; then
        TAG="$2"
    fi
    ;;
    -p|--podman)
    if [[ -n ${1} ]]; then
        USEPODMAN=true
    fi
    ;;
    -h|--help)
    if [[ -n ${1} ]]; then
        usage
    fi
    ;;
    --) # end argument parsing
    shift
    break
    ;;
    -*) # unsupported flags
    >&2 echo "ERROR: Unsupported flag: '$1'"
    usage
    exit 1
    ;;
esac
shift
done

#Check all mandatory variables set
VARIABLES=(CS_CLIENT_ID CS_CLIENT_SECRET REPO TAG)
{
    for VAR_NAME in "${VARIABLES[@]}"; do
        [ -z "${!VAR_NAME}" ] && echo "$VAR_NAME is unset refer to help to set" && VAR_UNSET=true
    done
        [ -n "$VAR_UNSET" ] && usage
}

#Check if CS_REGION and set API endpoint and convert to lower, if unset use "us-1"
if [[ -z "${CS_REGION}" ]]; then
    echo "\$CS_REGION variable not set, assuming US-1, set with -f or --region"
    REGION="us-1"
    API="api"
    PUSHREGISTRY="container-upload.us-1.crowdstrike.com"
else
    REGION=$(echo "${CS_REGION}" | tr '[:upper:]' '[:lower:]') #Convert to lowercase if user entered as UPPERCASE
    API="api.${REGION}"
    PUSHREGISTRY="container-upload.${REGION}.crowdstrike.com"
fi

#Check if user wants to use PODMAN instead of DOCKER
if [[ $USEPODMAN = true ]]; then
    RUNTIME=podman
else
    RUNTIME=docker
fi

echo "Logging into CrowdStrike Image Push Registry"
${RUNTIME} login --username  "${CS_CLIENT_ID}" --password "${CS_CLIENT_SECRET}" "${PUSHREGISTRY}"

echo "Tagging Image as ${PUSHREGISTRY}/${REPO}:${TAG}"
${RUNTIME} tag "${REPO}:${TAG}" "${PUSHREGISTRY}/${REPO}:${TAG}"

echo "Pushing Image to ${PUSHREGISTRY}/${REPO}:${TAG}"
${RUNTIME} push "${PUSHREGISTRY}/${REPO}:${TAG}"

echo "Getting token to retrieve image report"
BEARER=$(curl \
--data "client_id=${CS_CLIENT_ID}&client_secret=${CS_CLIENT_SECRET}" \
--request POST \
--silent \
https://"${API}".crowdstrike.com/oauth2/token | jq -r '.access_token')


echo "Checking if report is ready"

attempt_counter=1
max_attempts=15

while [ "$attempt_counter" -le "$max_attempts" ] || [ "$httpstatus" != 200 ]; do
    if [ "$attempt_counter" -eq "$max_attempts" ]
    then
        echo "Max attempts reached"
        exit 1
    fi
    httpstatus=$(curl --silent --head --fail --header "Authorization: Bearer ${BEARER}" --request GET "https://${PUSHREGISTRY}/reports?repository=${REPO}&tag=${TAG}" -o /dev/null -w '%{http_code}\n')
    
    case $httpstatus in
        200)
            echo "Report is ready, printing:"
            break
            ;;
        ""|400)
            echo "Report not ready, retrying in 10 seconds"
            attempt_counter=$(( attempt_counter + 1))
            sleep 10
            ;;
        *)
            echo "Unexpected status code: ${httpstatus}"
            exit 1
        esac
done
    
curl --silent --header "Authorization: Bearer ${BEARER}" --request GET "https://${PUSHREGISTRY}/reports?repository=${REPO}&tag=${TAG}" | jq '.'

