#!/bin/bash

BACKOFF_MIN_MS=10
BACKOFF_MAX_MS=50

if [[ ${#} != 4 ]]; then
  echo "Usage:"
  echo "${0} [default/backoff/prob/interest] [numNodes] [linkDelayMs] [trialNum]"
  exit 1
fi

experiment=${1}
numNodes=${2}
linkDelayMs=${3}
trialNum=${4}

logPath=logs/${experiment}-${numNodes}nodes-${linkDelayMs}ms-trial${trialNum}
mkdir -p ${logPath}

echo "=> Creating networks..."
docker network create --subnet 10.0.0.0/24 217b-net

echo -e "\n=> Creating nodes..."
docker run -itd --privileged --name 217b-c --mount type=bind,source="$(pwd)/${logPath}",target="/logs" 217b-dedup bash
for node in $(seq 1 ${numNodes}); do
  docker run -itd --privileged --name 217b-n${node} --mount type=bind,source="$(pwd)/${logPath}",target="/logs" 217b-dedup bash
done

echo -e "\n=> Attaching to networks..."
docker network connect 217b-net 217b-c --ip 10.0.0.2
for node in $(seq 1 ${numNodes}); do
  docker network connect 217b-net 217b-n${node} --ip 10.0.0.$(expr 2 + ${node})
done

echo -e "\n=> Simulating delay on links..."
docker exec -it 217b-c tc qdisc add dev eth1 root netem delay ${linkDelayMs}ms
for node in $(seq 1 ${numNodes}); do
  docker exec -it 217b-n${node} tc qdisc add dev eth1 root netem delay ${linkDelayMs}ms
done

echo -e "\n=> Enabling features and logging..."
if [[ "${experiment}" != "default" ]]; then
  if [[ "${experiment}" == "backoff" ]]; then
    featureOption="backoff_data_suppression"
  elif [[ "${experiment}" == "prob" ]]; then
    featureOption="prob_data_suppression"
  elif [[ "${experiment}" == "interest" ]]; then
    featureOption="interest_suppression"
  fi
  infoedit="infoedit -f /usr/local/etc/ndn/nfd.conf -s face_system.general.${featureOption} -v yes"
fi

echo -e "\n=> Enabling tested features..."
docker exec -it 217b-c infoedit -f /usr/local/etc/ndn/nfd.conf -s log.default_level -v DEBUG
for node in $(seq 1 ${numNodes}); do
  if [[ -v infoedit ]]; then
    docker exec -it 217b-n${node} ${infoedit}
  fi
  docker exec -it 217b-n${node} infoedit -f /usr/local/etc/ndn/nfd.conf -s log.default_level -v DEBUG
  docker exec -it 217b-n${node} infoedit -f /usr/local/etc/ndn/nfd.conf -s face_system.general.backoff_interval_begin -v ${BACKOFF_MIN_MS}
  docker exec -it 217b-n${node} infoedit -f /usr/local/etc/ndn/nfd.conf -s face_system.general.backoff_interval_end -v ${BACKOFF_MAX_MS}
done

echo -e "\n=> Starting NFD..."
docker exec -it 217b-c bash -c "ndnsec-keygen /localhost/operator | ndnsec-install-cert -"
docker exec -it 217b-c bash -c "nfd &>/logs/nfd-c.log & sleep 1"
for node in $(seq 1 ${numNodes}); do
  docker exec -it 217b-n${node} bash -c "ndnsec-keygen /localhost/operator | ndnsec-install-cert -"
  docker exec -it 217b-n${node} bash -c "nfd &>/logs/nfd-n${node}.log & sleep 1"
done

echo -e "\n=> Registering routes..."
if [[ "${experiment}" == "interest" ]]; then
  for node in $(seq 1 ${numNodes}); do
    docker exec -it 217b-n${node} nfdc route add /test-prefix 257 # Must specify ID since ether://[01:00:5e:00:17:aa] is on both interfaces

  done
else
  docker exec -it 217b-c nfdc route add /test-prefix 257 # Must specify ID since ether://[01:00:5e:00:17:aa] is on both interfaces
fi

echo -e "\n=> Starting producers..."
if [[ "${experiment}" == "interest" ]]; then
  docker exec -d 217b-c bash -c "echo 'testtesttest' | ndnpoke /test-prefix 2>&1 &>/logs/producer.log"
else
  for node in $(seq 1 ${numNodes}); do
    docker exec -d 217b-n${node} bash -c "echo 'testtesttest' | ndnpoke /test-prefix 2>&1 &>/logs/producer-n${node}.log"
  done
fi

echo -e "\n=> Starting consumers..."
if [[ "${experiment}" == "interest" ]]; then
  for node in $(seq 1 ${numNodes}); do
    docker exec -it 217b-n${node} bash -c "ndnpeek -p /test-prefix 2>&1 &>/logs/consumer-n${node}.log"
    sleep 1
  done
else
  docker exec -it 217b-c bash -c "ndnpeek -p /test-prefix 2>&1 | tee /logs/consumer.log"
fi

echo -e "\n=> Letting things settle...\n"
sleep 10

echo -e "\n=> Stopping NFD..."
docker exec -it 217b-c killall nfd
for node in $(seq 1 ${numNodes}); do
  docker exec -it 217b-n${node} killall nfd
done

echo -e "\n=> Stopping nodes..."
docker stop 217b-c
for node in $(seq 1 ${numNodes}); do
  docker stop 217b-n${node}
done

echo -e "\n=> Destroying nodes..."
docker rm 217b-c
for node in $(seq 1 ${numNodes}); do
  docker rm 217b-n${node}
done

echo -e "\n=> Destroying networks"
docker network rm 217b-net
