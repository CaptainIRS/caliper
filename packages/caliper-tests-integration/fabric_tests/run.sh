#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Print all commands.
set -v

# Grab the parent (fabric_tests) directory.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${DIR}"

if [[ ! -d "bin" || ! -d "config" ]]; then
  curl -sSL -k https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/bootstrap.sh | bash -s -- 2.4.3 -d -s
fi

npm install -g @hyperledger-labs/weft

export PATH=${DIR}/bin:$PATH

export MICROFAB_CONFIG='{
    "ordering_organizations": {
        "name": "Orderer"
    },
    "endorsing_organizations":[
        {
            "name": "Org1"
        },
        {
            "name": "Org2"
        }
    ],
    "channels":[
        {
            "name": "mychannel",
            "endorsing_organizations":[
                "Org1",
                "Org2"
            ]
        },
        {
            "name": "yourchannel",
            "endorsing_organizations":[
                "Org1",
                "Org2"
            ]
        }
    ]
}'
export CHAINCODE_NAME="marbles"

export CFG=$DIR/_cfg/uf
rm -rf $CFG
mkdir -p $CFG

docker run --name microfab -p 8080:8080 --add-host host.docker.internal:host-gateway --rm -d -e MICROFAB_CONFIG="${MICROFAB_CONFIG}"  ibmcom/ibp-microfab:0.0.16
sleep 5

curl -s http://console.127-0-0-1.nip.io:8080/ak/api/v1/components | weft microfab -w $CFG/_wallets -p $CFG/_gateways -m $CFG/_msp -f

export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=$CFG/_msp/Org1/org1admin/msp
export CORE_PEER_ADDRESS=org1peer-api.127-0-0-1.nip.io:8080
export FABRIC_CFG_PATH=$DIR/config
export CORE_PEER_CLIENT_CONNTIMEOUT=15s
export CORE_PEER_DELIVERYCLIENT_CONNTIMEOUT=15s

pushd $DIR/src/${CHAINCODE_NAME}/node

peer lifecycle chaincode package ${CHAINCODE_NAME}.tar.gz --path . --lang node --label ${CHAINCODE_NAME}

export CHAINCODE_ID=$(peer lifecycle chaincode calculatepackageid ${CHAINCODE_NAME}.tar.gz)
echo "Chaincode ID: ${CHAINCODE_ID}"

peer lifecycle chaincode install ${CHAINCODE_NAME}.tar.gz

peer lifecycle chaincode approveformyorg --channelID mychannel --name mymarbles -v v0 --package-id $CHAINCODE_ID --sequence 1 --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"
peer lifecycle chaincode approveformyorg --channelID yourchannel --name yourmarbles -v v0 --package-id $CHAINCODE_ID --sequence 1 --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"

export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_MSPCONFIGPATH=$CFG/_msp/Org2/org2admin/msp
export CORE_PEER_ADDRESS=org2peer-api.127-0-0-1.nip.io:8080

peer lifecycle chaincode install ${CHAINCODE_NAME}.tar.gz

peer lifecycle chaincode approveformyorg --channelID mychannel --name mymarbles -v v0 --package-id $CHAINCODE_ID --sequence 1 --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"
peer lifecycle chaincode approveformyorg --channelID yourchannel --name yourmarbles -v v0 --package-id $CHAINCODE_ID --sequence 1 --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"

peer lifecycle chaincode commit --channelID mychannel --name mymarbles -v v0 --sequence 1  --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"
peer lifecycle chaincode querycommitted --channelID=mychannel

peer lifecycle chaincode commit --channelID yourchannel --name yourmarbles -v v0 --sequence 1  --connTimeout 15s --signature-policy "OR('Org1MSP.member','Org2MSP.member')"
peer lifecycle chaincode querycommitted --channelID=yourchannel

popd

curl -s http://console.127-0-0-1.nip.io:8080/ak/api/v1/components | weft microfab -w $CFG/_wallets -p $CFG/_gateways -m $CFG/_msp -f

dispose () {
    JOBS=$(jobs -p)
    if [ -n "$JOBS" ]; then
        echo "Killing jobs: $JOBS"
        kill $JOBS
    fi
    docker ps -a
    docker logs microfab > /tmp/microfab.log
    docker stop microfab
    ${CALL_METHOD} launch manager --caliper-workspace phase6 --caliper-flow-only-end
}

trap 'dispose' EXIT

# change default settings (add config paths too)
export CALIPER_PROJECTCONFIG=../caliper.yaml

# bind during CI tests, using the package dir as CWD
# Note: do not use env variables for binding settings, as subsequent launch calls will pick them up and bind again
# Note: Fabric 1.4 binding is cached in CI
export FABRIC_VERSION=1.4.20
export NODE_PATH="$SUT_DIR/cached/v$FABRIC_VERSION/node_modules"
if [[ "${BIND_IN_PACKAGE_DIR}" = "true" ]]; then
    mkdir -p $SUT_DIR/cached/v$FABRIC_VERSION
    pushd $SUT_DIR/cached/v$FABRIC_VERSION
    ${CALL_METHOD} bind \
        --caliper-bind-sut fabric:$FABRIC_VERSION \
        --caliper-bind-args="--prefix $SUT_DIR/cached/v$FABRIC_VERSION"
    popd
fi

# PHASE 1: just starting the network
${CALL_METHOD} launch manager --caliper-workspace phase1 --caliper-flow-only-start
rc=$?
if [[ ${rc} != 0 ]]; then
    echo "Failed CI step 1";
    exit ${rc};
fi

# PHASE 2: testing through the low-level API
${CALL_METHOD} launch manager --caliper-workspace phase2 --caliper-flow-only-test
rc=$?
if [[ ${rc} != 0 ]]; then
    echo "Failed CI step 2";
    exit ${rc};
fi

# PHASE 3: testing through the gateway API (v1 SDK)
${CALL_METHOD} launch manager --caliper-workspace phase3 --caliper-flow-only-test --caliper-fabric-gateway-enabled
rc=$?
if [[ ${rc} != 0 ]]; then
    echo "Failed CI step 3";
    exit ${rc};
fi

# BIND with 2.2 SDK, using the package dir as CWD
# Note: do not use env variables for unbinding settings, as subsequent launch calls will pick them up and bind again
# Note: Fabric 2.2 binding is cached in CI
export FABRIC_VERSION=2.2.14
export NODE_PATH="$SUT_DIR/cached/v$FABRIC_VERSION/node_modules"
if [[ "${BIND_IN_PACKAGE_DIR}" = "true" ]]; then
    mkdir -p $SUT_DIR/cached/v$FABRIC_VERSION
    pushd $SUT_DIR/cached/v$FABRIC_VERSION
    ${CALL_METHOD} bind --caliper-bind-sut fabric:$FABRIC_VERSION
    popd
fi

# PHASE 4: testing through the gateway API (v2 SDK)
${CALL_METHOD} launch manager --caliper-workspace phase4 --caliper-flow-only-test
rc=$?
if [[ ${rc} != 0 ]]; then
    echo "Failed CI step 4";
    exit ${rc};
fi

# BIND with 2.4 SDK, using the package dir as CWD
# Note: do not use env variables for unbinding settings, as subsequent launch calls will pick them up and bind again
# Note: Fabric 2.4 binding is NOT cached in CI. This binding is lightweight so doesn't take much time and allows the 2.4 binding to be modified in the config.yaml binding file
export FABRIC_VERSION=2.4
export NODE_PATH="$SUT_DIR/uncached/v$FABRIC_VERSION/node_modules"
if [[ "${BIND_IN_PACKAGE_DIR}" = "true" ]]; then
    mkdir -p $SUT_DIR/uncached/v$FABRIC_VERSION
    pushd $SUT_DIR/uncached/v$FABRIC_VERSION
    ${CALL_METHOD} bind --caliper-bind-sut fabric:$FABRIC_VERSION
    popd
fi

# PHASE 5: testing through the peer gateway API (fabric-gateway SDK)
${CALL_METHOD} launch manager --caliper-workspace phase5 --caliper-flow-only-test
rc=$?
if [[ ${rc} != 0 ]]; then
    echo "Failed CI step 5";
    exit ${rc};
fi
