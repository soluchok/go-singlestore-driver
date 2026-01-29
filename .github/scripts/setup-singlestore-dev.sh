#!/bin/bash
set -eu

# this script must be run from the top-level of the repo
cd "$(git rev-parse --show-toplevel)"

DEFAULT_SINGLESTORE_VERSION="9.0"
VERSION="${SINGLESTORE_VERSION:-$DEFAULT_SINGLESTORE_VERSION}"
IMAGE_NAME="ghcr.io/singlestore-labs/singlestoredb-dev:latest"
CONTAINER_NAME="singlestore-integration-go-driver"

S2_MASTER_PORT=${S2_TEST_PORT:-5506}
S2_AGG_PORT_1=${S2_AGG_PORT_1:-5507}
S2_AGG_PORT_2=${S2_AGG_PORT_2:-5508}
SINGLESTORE_PASSWORD=${S2_TEST_PASS:-p}
TEST_DATABASE=${S2_TEST_DB_NAME:-gotest}

EXISTS=$(docker inspect ${CONTAINER_NAME} >/dev/null 2>&1 && echo 1 || echo 0)

./.github/scripts/generate-ssl-certs.sh

if [[ "${EXISTS}" -eq 1 ]]; then
  EXISTING_IMAGE_NAME=$(docker inspect -f '{{.Config.Image}}' ${CONTAINER_NAME})
  if [[ "${IMAGE_NAME}" != "${EXISTING_IMAGE_NAME}" ]]; then
    echo "Existing container ${CONTAINER_NAME} has image ${EXISTING_IMAGE_NAME} when ${IMAGE_NAME} is expected; recreating container."
    docker rm -f ${CONTAINER_NAME}
    EXISTS=0
  fi
fi

if [[ "${EXISTS}" -eq 0 ]]; then
    docker run -d \
        --name ${CONTAINER_NAME} \
        -v ${PWD}/.github/scripts/ssl:/test-ssl \
        -v ${PWD}/.github/scripts/jwt:/test-jwt \
        -e SINGLESTORE_LICENSE=${SINGLESTORE_LICENSE} \
        -e ROOT_PASSWORD="${SINGLESTORE_PASSWORD}" \
        -e SINGLESTORE_VERSION=${VERSION} \
        -p ${S2_MASTER_PORT}:3306 -p ${S2_AGG_PORT_1}:3307 -p ${S2_AGG_PORT_2}:3308 \
        ${IMAGE_NAME}
fi

singlestore-wait-start() {
  echo -n "Waiting for SingleStore to start..."
  while true; do
      if mysql -u root -h 127.0.0.1 -P ${S2_MASTER_PORT} -p"${SINGLESTORE_PASSWORD}" -e "SELECT 1" >/dev/null 2>/dev/null; then
          break
      fi
      echo -n "."
      sleep 0.2
  done
  echo ". Success!"
}

singlestore-wait-start

if [[ "${EXISTS}" -eq 0 ]]; then
    echo
    echo "Creating aggregator nodes"
    docker exec ${CONTAINER_NAME} memsqlctl create-node --yes --password ${SINGLESTORE_PASSWORD} --port 3308
    docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key minimum_core_count --value 0
    docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key minimum_memory_mb --value 0
    docker exec ${CONTAINER_NAME} memsqlctl start-node --yes --all
    docker exec ${CONTAINER_NAME} memsqlctl add-aggregator --yes --host 127.0.0.1 --password ${SINGLESTORE_PASSWORD} --port 3308
fi

echo
echo "Setting up JWT"
docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key jwt_auth_config_file --value /test-jwt/jwt_auth_config.json

echo "Setting up SSL"
docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key ssl_ca --value /test-ssl/test-ca-cert.pem
docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key ssl_cert --value /test-ssl/test-s2-cert.pem
docker exec ${CONTAINER_NAME} memsqlctl update-config --yes --all --key ssl_key --value /test-ssl/test-s2-key.pem

echo "Restarting cluster"
docker restart ${CONTAINER_NAME}
singlestore-wait-start

echo "Setting up root-ssl user"
mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" -e 'CREATE USER IF NOT EXISTS "root-ssl"@"%" REQUIRE SSL'
mysql -u root -h 127.0.0.1 -P $S2_AGG_PORT_1  -p"${SINGLESTORE_PASSWORD}" -e 'CREATE USER IF NOT EXISTS "root-ssl"@"%" REQUIRE SSL'

mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" -e 'GRANT ALL PRIVILEGES ON *.* TO "root-ssl"@"%" WITH GRANT OPTION'
mysql -u root -h 127.0.0.1 -P $S2_AGG_PORT_1  -p"${SINGLESTORE_PASSWORD}" -e 'GRANT ALL PRIVILEGES ON *.* TO "root-ssl"@"%" WITH GRANT OPTION'
echo "Done!"

echo
echo "Ensuring child nodes are connected using container IP"
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_NAME})
CURRENT_LEAF_IP=$(mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e 'SELECT host FROM information_schema.leaves')
if [[ ${CONTAINER_IP} != "${CURRENT_LEAF_IP}" ]]; then
    # remove leaf with current ip
    mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e "REMOVE LEAF '${CURRENT_LEAF_IP}':3307"
    # add leaf with correct ip
    mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e "ADD LEAF root:'${SINGLESTORE_PASSWORD}'@'${CONTAINER_IP}':3307"
fi
CURRENT_AGG_IP=$(mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e 'SELECT host FROM information_schema.aggregators WHERE master_aggregator=0')
if [[ ${CONTAINER_IP} != "${CURRENT_AGG_IP}" ]]; then
    # remove aggregator with current ip
    mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e "REMOVE AGGREGATOR '${CURRENT_AGG_IP}':3308"
    # add aggregator with correct ip
    mysql -u root -h 127.0.0.1 -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" --batch -N -e "ADD AGGREGATOR root:'${SINGLESTORE_PASSWORD}'@'${CONTAINER_IP}':3308"
fi
echo "Done!"

echo "Preparing database and jwt user..."
mysql -h 127.0.0.1 -u root -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${TEST_DATABASE}"
mysql -h 127.0.0.1 -u root -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" -e "CREATE USER IF NOT EXISTS 'test_jwt_user' IDENTIFIED WITH authentication_jwt"
mysql -h 127.0.0.1 -u root -P $S2_MASTER_PORT -p"${SINGLESTORE_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${TEST_DATABASE}.* TO 'test_jwt_user'@'%'"
echo "Done!"
