#!/bin/bash

set -e

CATAPULT_GIT_URI="https://github.com/redhat-kontinuity/catapult"
CATAPULT_GIT_REF="master"
BASE_IMAGE="openshift/wildfly-100-centos7"
OC_BINARY="/home/atomic-sig/oc"
APP_NAME="catapult"
USERNAME="admin"
PASSWORD="admin"
COUNTER=0
DELAY=10
MAX_COUNTER=30
REPLICAS=1
PROJECT="distortion"


# Process Input
for i in "$@"
do
  case $i in
    -h=*|--host=*)
      HOST="${i#*=}"
      shift;;
    -u=*|--username=*)
      USERNAME="${i#*=}"
      shift;;
    -p=*|--password=*)
      PASSWORD="${i#*=}"
      shift;;
     -b=*|--binary=*)
      OC_BINARY="${i#*=}"
      shift;;      
    --github-client-id=*)
      KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_ID="${i#*=}"
      shift;;
    --github-client-secret=*)
      KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_SECRET="${i#*=}"
      shift;;
    --git-repository=*)
      CATAPULT_GIT_URI="${i#*=}"
      shift;;
   --git-ref=*)
      CATAPULT_GIT_REF="${i#*=}"
      shift;; 
  esac
done


if [ -z $HOST ] || [ -z $KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_ID ] || [ -z $KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_SECRET ]; then
  echo "Error: Required Values Have Not Been Set"
  exit 1
fi

function wait_for_running_first_build() {
    APP_NAME=$1
    NAMESPACE=$2

    while true
    do
        BUILD_STATUS=$(${OC_BINARY} get builds ${APP_NAME}-1 -n ${NAMESPACE} --template='{{ .status.phase }}')

        if [ "$BUILD_STATUS" == "Running" ] || [ "$BUILD_STATUS" == "Complete" ] || [ "$BUILD_STATUS" == "Failed" ]; then
           break
        fi
    done

}


# Login to Environment
${OC_BINARY} login -u=${USERNAME} -p=${PASSWORD} --insecure-skip-tls-verify=true ${HOST}


# Create new Project
${OC_BINARY} new-project ${PROJECT}


# Create New Application
${OC_BINARY} new-app ${BASE_IMAGE}~${CATAPULT_GIT_URI}#${CATAPULT_GIT_REF} --name=${APP_NAME}

# Import Image Streams
${OC_BINARY} import-image ${BASE_IMAGE##*/}

# Set Environment Variables
${OC_BINARY} env dc/${APP_NAME} OPENSHIFT_SMTP_HOST=localhost KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_ID=${KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_ID} KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_SECRET=${KONTINUITY_CATAPULT_GITHUB_APP_CLIENT_SECRET}

# Expose Route
${OC_BINARY} expose svc ${APP_NAME}

echo "Pausing for a moment before tracking build..."
sleep 5

# Track Build
echo
echo "Waiting for first build to begin..."
echo
wait_for_running_first_build "${APP_NAME}" "${PROJECT}"

${OC_BINARY} build-logs -f ${APP_NAME}-1


echo "Pausing for a moment before verifying deployment..."
sleep 5

LATEST_DC_VERSION=$(${OC_BINARY} get dc ${APP_NAME}  --template='{{ .status.latestVersion }}')

RC_NAME=${APP_NAME}-${LATEST_DC_VERSION}

# Cycle Through Status to see if we have hit our deployment target
while [ $COUNTER -lt $MAX_COUNTER ]
do

    RC_REPLICAS=$(${OC_BINARY} get rc ${RC_NAME} --template='{{ .status.replicas }}')

	# Check if build succeeded or failed
	if [ $RC_REPLICAS -eq $REPLICAS ]; then
		echo
		break
	fi


	echo -n "."
	COUNTER=$(( $COUNTER + 1 ))
    
    if [ $COUNTER -eq $MAX_COUNTER ]; then
      echo "Max Validation Attempts Exceeded. Failed Verifying Application Deployment..."
      exit 1
    fi

	sleep $DELAY

done

echo "${APP_NAME} successfully deployed"

echo "Pausing 10 seconds before attempting validation..."
sleep 10

APP_HOSTNAME=$(${OC_BINARY} get routes ${APP_NAME} --template='{{ .spec.host }}')
COUNTER=0

# Disable error checking
set +e

echo
echo -n "Validating Application"

while [ $COUNTER -lt $MAX_COUNTER ]
do
    
    RESPONSE=$(curl -s -o /dev/null -w '%{http_code}\n' http://${APP_HOSTNAME}/api/github/verify)
    
    if [ $RESPONSE -eq 200 ]; then
        echo 
        echo 
        echo "Application Verified"
        break
    fi

    echo -n "."

	COUNTER=$(( $COUNTER + 1 ))
    
    if [ $COUNTER -eq $MAX_COUNTER ]; then
      echo "Max Validation Attempts Exceeded. Failed Verifying Appliaction..."
      exit 1
    fi

	sleep $DELAY

done

echo
echo "Provisioning of ${APP_NAME} complete and validated!"
echo
