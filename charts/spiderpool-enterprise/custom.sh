#!/bin/bash

CHART_DIRECTORY=$1
[ ! -d "$CHART_DIRECTORY" ] && echo "custom shell: error, miss CHART_DIRECTORY $CHART_DIRECTORY " && exit 1

CURRENT_DIR_PATH=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)

echo "custom shell: CHART_DIRECTORY $CHART_DIRECTORY"
echo "CHART_DIRECTORY $(ls)"
echo "CURRENT_DIR_PATH: " $CURRENT_DIR_PATH

#========================= add your customize bellow ====================
#===============================

set -o errexit
set -o pipefail
set -o nounset

if ! which yq &>/dev/null ; then
    echo " 'yq' no found, try to install..."
    YQ_VERSION=v4.30.6
    YQ_BINARY="yq_$(uname | tr 'A-Z' 'a-z')_amd64"
    wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}.tar.gz -O /tmp/yq.tar.gz &&
     tar -xzf /tmp/yq.tar.gz -C /tmp &&
     mv /tmp/${YQ_BINARY} /usr/bin/yq
fi

OS=$(uname -s | tr 'A-Z' 'a-z')
SED_COMMAND="sed"
if [ "${OS}" == "darwin" ]; then
    SED_COMMAND="gsed"
fi

#==============================
echo "insert custom resources"
export CUSTOM_SPIDERPOOL_AGENT_CPU='10m'
export CUSTOM_SPIDERPOOL_AGENT_MEMORY='32Mi'
export CUSTOM_SPIDERPOOL_CONTROLLER_CPU=${CUSTOM_SPIDERPOOL_AGENT_CPU}
export CUSTOM_SPIDERPOOL_CONTROLLER_MEMORY='64Mi'
export CUSTOM_SPIDERPOOL_INIT_CPU=${CUSTOM_SPIDERPOOL_AGENT_CPU}
export CUSTOM_SPIDERPOOL_INIT_MEMORY=${CUSTOM_SPIDERPOOL_AGENT_MEMORY}

yq -i '
    .spiderpool.global.imageRegistryOverride="ghcr.m.daocloud.io" |
    .spiderpool.ipam.enableIPv4=true |
    .spiderpool.ipam.enableIPv6=false |
    .spiderpool.ipam.spidersubnet.enable=true |
    .spiderpool.coordinator.detectGateway = true |
    .spiderpool.coordinator.detectIPConflict = true | 
    .spiderpool.multus.multusCNI.uninstall=true |
    .spiderpool.multus.multusCNI.defaultCniCRName="" |
    .spiderpool.multus.multusCNI.image.registry="ghcr.m.daocloud.io" |
    .spiderpool.clusterDefaultPool.installIPv4IPPool=true |
    .spiderpool.clusterDefaultPool.installIPv6IPPool=false |
    .spiderpool.clusterDefaultPool.installIPv6IPPool=false |
    .spiderpool.clusterDefaultPool.ipv4Subnet="192.168.0.0/16" |
    .spiderpool.clusterDefaultPool.ipv6Subnet="fd00::/112" |
    .spiderpool.clusterDefaultPool.ipv4Gateway="192.168.0.1" |
    .spiderpool.clusterDefaultPool.ipv6Gateway="fd00::1" |
    .spiderpool.clusterDefaultPool.ipv4IPRanges = ["192.168.0.10-192.168.0.100"] + .spiderpool.clusterDefaultPool.ipv4IPRanges |
    .spiderpool.clusterDefaultPool.ipv6IPRanges = ["fd00::10-fd00::100"] + .spiderpool.clusterDefaultPool.ipv6IPRanges |
    .spiderpool.spiderpoolAgent.image.registry="ghcr.m.daocloud.io" |
    .spiderpool.spiderpoolAgent.resources.requests.cpu=strenv(CUSTOM_SPIDERPOOL_AGENT_CPU) |
    .spiderpool.spiderpoolAgent.resources.requests.memory=strenv(CUSTOM_SPIDERPOOL_AGENT_MEMORY) |
    .spiderpool.spiderpoolController.image.registry="ghcr.m.daocloud.io" |
    .spiderpool.spiderpoolController.resources.requests.cpu=strenv(CUSTOM_SPIDERPOOL_CONTROLLER_CPU) |
    .spiderpool.spiderpoolController.resources.requests.memory=strenv(CUSTOM_SPIDERPOOL_CONTROLLER_MEMORY) |
    .spiderpool.spiderpoolController.tolerations[0].effect = "NoSchedule" |
    .spiderpool.spiderpoolInit.image.registry="ghcr.m.daocloud.io" | 
    .spiderpool.spiderpoolInit.resources.requests.cpu=strenv(CUSTOM_SPIDERPOOL_INIT_CPU) |
    .spiderpool.spiderpoolInit.resources.requests.memory=strenv(CUSTOM_SPIDERPOOL_INIT_MEMORY) | 
    .spiderpool.plugins.image.registry="ghcr.m.daocloud.io" |
    .spiderpool.rdma.rdmaSharedDevicePlugin.image.registry="ghcr.m.daocloud.io" |
    .spiderpool.dra.hostDevicePath="/usr/lib/libsmc-preload.so" |
    .spiderpool.netmaterial.image.registry="ghcr.m.daocloud.io" | 
    .spiderpool.netmaterial.image.repository="daocloud/netmaterial" |
    .spiderpool.netmaterial.image.tag="latest" |
    .spiderpool.netmaterial.image.pullPolicy="IfNotPresent" 
' ${CHART_DIRECTORY}/values.yaml

yq -i '.name="spiderpool-enterprise" ' ${CHART_DIRECTORY}/Chart.yaml

if ! grep "keywords:" ${CHART_DIRECTORY}/Chart.yaml &>/dev/null ; then
    echo "keywords:" >> ${CHART_DIRECTORY}/Chart.yaml
    echo "  - networking" >> ${CHART_DIRECTORY}/Chart.yaml
    echo "  - ipam" >> ${CHART_DIRECTORY}/Chart.yaml
fi

# dra smc related
echo "insert dra smc config"
${SED_COMMAND} -i -e "/initContainers:/r ${CURRENT_DIR_PATH}/append/smc_initcontainer.txt" ${CHART_DIRECTORY}/charts/spiderpool/templates/daemonset.yaml

matched_line=$(${SED_COMMAND} -n '/Values.dra.enabled/=' ${CHART_DIRECTORY}/charts/spiderpool/templates/daemonset.yaml |${SED_COMMAND} -n "$"p )
[ -z "$matched_line" ] && echo "unexpected empty matched_line, exit 1" && exit 1

echo "matched volume line is: " $matched_line
${SED_COMMAND} -i -e "${matched_line}r ${CURRENT_DIR_PATH}/append/smc_volumes.txt" ${CHART_DIRECTORY}/charts/spiderpool/templates/daemonset.yaml

echo '{{/*
return the netermarial image
*/}}
{{- define "netmaterial.image" -}}
{{- $registryName := .Values.netmaterial.image.registry -}}
{{- $repositoryName := .Values.netmaterial.image.repository -}}
{{- if .Values.global.imageRegistryOverride }}
    {{- printf "%s/%s" .Values.global.imageRegistryOverride $repositoryName -}}
{{ else if $registryName }}
    {{- printf "%s/%s" $registryName $repositoryName -}}
{{- else -}}
    {{- printf "%s" $repositoryName -}}
{{- end -}}
{{- if .Values.netmaterial.image.tag -}}
    {{- printf ":%s" .Values.netmaterial.image.tag -}}
{{- else -}}
    {{- printf ":%s" "latest" -}}
{{- end -}}
{{- end -}}' >> ${CHART_DIRECTORY}/charts/spiderpool/templates/_helpers.tpl

rm -f ${CHART_DIRECTORY}/values.yaml-E || true

exit 0