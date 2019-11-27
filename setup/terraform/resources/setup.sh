#! /bin/bash

echo "-- Commencing SingleNodeCluster Setup Script"

set -e
set -u

if [ "$USER" != "root" ]; then
  echo "ERROR: This script ($0) must be executed by root"
  exit 1
fi

CLOUD_PROVIDER=${1:-aws}
SSH_USER=${2:-}
SSH_PWD=${3:-}
NAMESPACE=${4:-}
DOCKER_DEVICE=${5:-}

export NAMESPACE

BASE_DIR=$(cd $(dirname $0); pwd -L)
source $BASE_DIR/common.sh
KEY_FILE=${BASE_DIR}/myRSAkey

load_stack $NAMESPACE

#########  Start Packer Installation

echo "-- Testing if this is a pre-packed image by looking for existing Cloudera Manager repo"
CM_REPO_FILE=/etc/yum.repos.d/cloudera-manager.repo
if [[ ! -f $CM_REPO_FILE ]]; then
  echo "-- Cloudera Manager repo not found, assuming not prepacked"
  echo "-- Installing base dependencies"
  yum_install ${JAVA_PACKAGE_NAME} vim wget curl git bind-utils epel-release
  yum_install python-pip npm gcc-c++ make

  echo "-- Install CM yum repo"
  wget --progress=dot:giga ${CM_REPO_FILE_URL} -O $CM_REPO_FILE
  sed -i -E "s#https?://[^/]*#${CM_BASE_URL}#g" $CM_REPO_FILE

  echo "-- Install MariaDB yum repo"
  cat - >/etc/yum.repos.d/MariaDB.repo <<EOF
  [mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.1/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF

  echo "-- Running remaining binary preinstalls"
  yum clean all
  rm -rf /var/cache/yum/
  yum repolist

  yum_install cloudera-manager-daemons cloudera-manager-agent cloudera-manager-server \
              MariaDB-server MariaDB-client shellinabox mosquitto jq transmission-cli
  npm install --quiet forever -g
  yum erase -y python-requests
  pip install --quiet --upgrade pip
  pip install --progress-bar off cm_client paho-mqtt pytest nipyapi
  systemctl disable mariadb

  echo "-- Install Maven"
  curl http://mirrors.sonic.net/apache/maven/maven-3/3.6.2/binaries/apache-maven-3.6.2-bin.tar.gz > /tmp/apache-maven-3.6.2-bin.tar.gz
  tar -C $(get_homedir $SSH_USER) -zxvf /tmp/apache-maven-3.6.2-bin.tar.gz
  rm -f /tmp/apache-maven-3.6.2-bin.tar.gz
  echo "export PATH=\$PATH:$(get_homedir $SSH_USER)/apache-maven-3.6.2/bin" >> $(get_homedir $SSH_USER)/.bash_profile

  echo "-- Get and extract CEM tarball to /opt/cloudera/cem"
  mkdir -p /opt/cloudera/cem
  wget --progress=dot:giga ${CEM_URL} -P /opt/cloudera/cem
  tar -zxf /opt/cloudera/cem/CEM-${CEM_VERSION}-centos7-tars-tarball.tar.gz -C /opt/cloudera/cem
  rm -f /opt/cloudera/cem/CEM-${CEM_VERSION}-centos7-tars-tarball.tar.gz

  echo "-- Install and configure EFM"
  EFM_TARBALL=$(find /opt/cloudera/cem/ -path "*/centos7/*" -name "efm-*-bin.tar.gz")
  EFM_BASE_NAME=$(basename $EFM_TARBALL | sed 's/-bin.tar.gz//')
  tar -zxf ${EFM_TARBALL} -C /opt/cloudera/cem
  ln -s /opt/cloudera/cem/${EFM_BASE_NAME} /opt/cloudera/cem/efm
  ln -s /opt/cloudera/cem/efm/bin/efm.sh /etc/init.d/efm
  chown -R root:root /opt/cloudera/cem/${EFM_BASE_NAME}
  rm -f /opt/cloudera/cem/efm/conf/efm.properties
  rm -f /opt/cloudera/cem/efm/conf/efm.conf
  cp $BASE_DIR/efm.properties /opt/cloudera/cem/efm/conf
  cp $BASE_DIR/efm.conf /opt/cloudera/cem/efm/conf

  echo "-- Install and configure MiNiFi"
  MINIFI_TARBALL=$(find /opt/cloudera/cem/ -path "*/centos7/*" -name "minifi-[0-9]*-bin.tar.gz")
  MINIFITK_TARBALL=$(find /opt/cloudera/cem/ -path "*/centos7/*" -name "minifi-toolkit-*-bin.tar.gz")
  MINIFI_BASE_NAME=$(basename $MINIFI_TARBALL | sed 's/-bin.tar.gz//')
  MINIFITK_BASE_NAME=$(basename $MINIFITK_TARBALL | sed 's/-bin.tar.gz//')
  tar -zxf ${MINIFI_TARBALL} -C /opt/cloudera/cem
  tar -zxf ${MINIFITK_TARBALL} -C /opt/cloudera/cem
  ln -s /opt/cloudera/cem/${MINIFI_BASE_NAME} /opt/cloudera/cem/minifi
  chown -R root:root /opt/cloudera/cem/${MINIFI_BASE_NAME}
  chown -R root:root /opt/cloudera/cem/${MINIFITK_BASE_NAME}
  rm -f /opt/cloudera/cem/minifi/conf/bootstrap.conf
  cp $BASE_DIR/bootstrap.conf /opt/cloudera/cem/minifi/conf
  /opt/cloudera/cem/minifi/bin/minifi.sh install

  echo "-- Disable services here for packer images - will reenable later"
  systemctl disable cloudera-scm-server
  systemctl disable cloudera-scm-agent
  systemctl disable minifi

  echo "-- Download and install MQTT Processor NAR file"
  wget http://central.maven.org/maven2/org/apache/nifi/nifi-mqtt-nar/1.8.0/nifi-mqtt-nar-1.8.0.nar -P /opt/cloudera/cem/minifi/lib
  chown root:root /opt/cloudera/cem/minifi/lib/nifi-mqtt-nar-1.8.0.nar
  chmod 660 /opt/cloudera/cem/minifi/lib/nifi-mqtt-nar-1.8.0.nar

  echo "-- Preloading large Parcels to /opt/cloudera/parcel-repo"
  mkdir -p /opt/cloudera/parcel-repo
  if [ "${#PARCEL_URLS[@]}" -gt 0 ]; then
    set -- "${PARCEL_URLS[@]}"
    while [ $# -gt 0 ]; do
      component=$1
      version=$2
      url=$3
      shift 3
      echo ">>> $component - $version - $url"
      curl --silent "${url%%/}/manifest.json" > /tmp/manifest.json
      parcel_name=$(jq -r '.parcels[] | select(.parcelName | contains("'"$version"'-el7.parcel")) | select(.components[] | .name == "'"$component"'").parcelName' /tmp/manifest.json)
      hash=$(jq -r '.parcels[] | select(.parcelName | contains("'"$version"'-el7.parcel")) | select(.components[] | .name == "'"$component"'").hash' /tmp/manifest.json)
      wget --no-clobber --progress=dot:giga "${url%%/}/${parcel_name}" -O "/opt/cloudera/parcel-repo/${parcel_name}"
      echo "$hash" > "/opt/cloudera/parcel-repo/${parcel_name}.sha"
      transmission-create -s 512 -o "/opt/cloudera/parcel-repo/${parcel_name}.torrent" "/opt/cloudera/parcel-repo/${parcel_name}"
    done
  fi

  echo "-- Configure and optimize the OS"
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
  echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.d/rc.local
  echo "echo never > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.d/rc.local
  # add tuned optimization https://www.cloudera.com/documentation/enterprise/latest/topics/cdh_admin_performance.html
  echo  "vm.swappiness = 1" >> /etc/sysctl.conf
  sysctl vm.swappiness=1
  timedatectl set-timezone UTC

  echo "-- Handle cases for cloud provider customisations"
  case "${CLOUD_PROVIDER}" in
        aws)
            echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
            systemctl restart chronyd
            ;;
        azure)
            umount /mnt/resource
            mount /dev/sdb1 /opt
            ;;
        gcp)
            ;;
        *)
            echo $"Usage: $0 {aws|azure|gcp} template-file [docker-device]"
            echo $"example: ./setup.sh azure default_template.json"
            echo $"example: ./setup.sh aws cluster_template.json /dev/xvdb"
            exit 1
  esac

  iptables-save > $BASE_DIR/firewall.rules
  FWD_STATUS=$(systemctl is-active firewalld || true)
  if [[ "${FWD_STATUS}" != "unknown" ]]; then
    systemctl disable firewalld
    systemctl stop firewalld
  fi
  setenforce 0
  if [[ -f /etc/selinux/config ]]; then
    sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  fi

  echo "-- Install JDBC connector"
  wget --progress=dot:giga ${JDBC_CONNECTOR_URL} -P ${BASE_DIR}/
  TAR_FILE=$(basename ${JDBC_CONNECTOR_URL})
  BASE_NAME=${TAR_FILE%.tar.gz}
  tar zxf ${BASE_DIR}/${TAR_FILE} -C ${BASE_DIR}/
  mkdir -p /usr/share/java/
  cp ${BASE_DIR}/${BASE_NAME}/${BASE_NAME}-bin.jar /usr/share/java/mysql-connector-java.jar

  echo "-- Install CSDs"
  for url in "${CSD_URLS[@]}"; do
    echo "---- Downloading $url"
    wget --progress=dot:giga ${url} -P /opt/cloudera/csd/
    # Patch CDSW CSD so that we can use it on CDP
    if [ "$url" == "$CDSW_CSD_URL" -a "$CM_MAJOR_VERSION" == "7" ]; then
      jar xvf /opt/cloudera/csd/CLOUDERA_DATA_SCIENCE_WORKBENCH-*.jar descriptor/service.sdl
      sed -i 's/"max" *: *"6"/"max" : "7"/g' descriptor/service.sdl
      jar uvf /opt/cloudera/csd/CLOUDERA_DATA_SCIENCE_WORKBENCH-*.jar descriptor/service.sdl
      rm -rf descriptor
    fi
  done

  echo "-- Enable password authentication"
  sed -i.bak 's/PasswordAuthentication *no/PasswordAuthentication yes/' /etc/ssh/sshd_config

  echo "-- Reset SSH user password"
  echo "$SSH_PWD" | sudo passwd --stdin "$SSH_USER"

  echo "-- Finished image preinstall"
else
  echo "-- Cloudera Manager repo already present, assuming this is a prewarmed image"
fi
####### Finish packer build

echo "-- Checking if executing packer build"
if [[ ! -z ${PACKER_BUILD:+x} ]]; then
  echo "-- Packer build detected, exiting with success"
  sleep 2
  exit 0
else
  echo "-- Packer build not detected, continuing with installation"
  sleep 2
fi

##### Start install

# Prewarm parcel directory
for parcel_file in $(find /opt/cloudera/parcel-repo -type f); do
  dd if=$parcel_file of=/dev/null bs=10M &
done

PUBLIC_IP=$(curl https://api.ipify.org/ 2>/dev/null || curl https://ifconfig.me 2> /dev/null)
PUBLIC_DNS=$(dig -x ${PUBLIC_IP} +short)

echo "-- Set /etc/hosts"
echo "$(hostname -I) $(hostname -f) edge2ai-1.dim.local" >> /etc/hosts

echo "-- Configure networking"
hostnamectl set-hostname $(hostname -f)
if [[ -f /etc/sysconfig/network ]]; then
  sed -i "/HOSTNAME=/ d" /etc/sysconfig/network
fi
echo "HOSTNAME=$(hostname -f)" >> /etc/sysconfig/network

echo "-- Generate self-signed certificate for ShellInABox with the needed SAN entries"
# Generate self-signed certificate for ShellInABox with the needed SAN entries
openssl req \
  -x509 \
  -nodes \
  -newkey 2048 \
  -keyout key.pem \
  -out cert.pem \
  -days 365 \
  -subj "/C=US/ST=California/L=San Francisco/O=Cloudera/OU=Data in Motion/CN=$(hostname -f)" \
  -extensions 'v3_user_req' \
  -config <( cat <<EOF
[ req ]
default_bits = 2048
default_md = sha256
distinguished_name = req_distinguished_name
req_extensions = v3_user_req
string_mask = utf8only

[ req_distinguished_name ]
countryName_default = XX
countryName_min = 2
countryName_max = 2
localityName_default = Default City
0.organizationName_default = Default Company Ltd
commonName_max = 64
emailAddress_max = 64

[ v3_user_req ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:$(hostname -f),DNS:${PUBLIC_DNS},IP:$(hostname -I),IP:${PUBLIC_IP}
EOF
)
cat key.pem cert.pem > /var/lib/shellinabox/certificate.pem
# Enable and start ShelInABox
systemctl enable shellinaboxd
systemctl start shellinaboxd

if [[ -n "${CDSW_BUILD}" ]]; then
    echo "CDSW_BUILD is set to '${CDSW_BUILD}'"
    # CDSW requires Centos 7.5, so we trick it to believe it is...
    echo "CentOS Linux release 7.5.1810 (Core)" > /etc/redhat-release
    # If user doesn't specify a device, tries to detect a free one to use
    # Device must be unmounted and have at least 200G of space
    if [[ "${DOCKER_DEVICE}" == "" ]]; then
      echo "Docker device was not specified in the command line. Will try to detect a free device to use"
      TMP_FILE=${BASE_DIR}/.device.list
      # Find devices that are not mounted and have size greater than or equal to 200G
      lsblk -o NAME,MOUNTPOINT,SIZE -s -p -n | awk '/^\// && NF == 2 && $NF ~ /([2-9]|[0-9][0-9])[0-9][0-9]G/' > "${TMP_FILE}"
      if [[ $(cat $TMP_FILE | wc -l) == 0 ]]; then
        echo "ERROR: Could not find any candidate devices."
        exit 1
      elif [[ $(cat ${TMP_FILE} | wc -l) -gt 1 ]]; then
        echo "ERROR: Found more than 1 possible devices to use:"
        cat ${TMP_FILE}
        exit 1
      else
        DOCKER_DEVICE=$(awk '{print $1}' ${TMP_FILE})
      fi
      rm -f ${TMP_FILE}
    fi
    echo "Docker device: ${DOCKER_DEVICE}"
else
    echo "CDSW_BUILD is unset, skipping CDSW installation";
fi

echo "--Configure and start MariaDB"
echo "-- Configure MariaDB"
cat ${BASE_DIR}/mariadb.config > /etc/my.cnf
systemctl enable mariadb
systemctl start mariadb

echo "-- Create DBs required by CM"
mysql -u root < ${BASE_DIR}/create_db.sql

echo "-- Secure MariaDB"
mysql -u root < ${BASE_DIR}/secure_mariadb.sql

echo "-- Prepare CM database 'scm'"
/opt/cloudera/cm/schema/scm_prepare_database.sh mysql scm scm supersecret1

echo "-- Install additional CSDs"
for csd in $(find $BASE_DIR/csds -name "*.jar"); do
  echo "---- Copying $csd"
  cp $csd /opt/cloudera/csd/
done

echo "-- Install additional parcels"
for parcel in $(find $BASE_DIR/parcels -name "*.parcel"); do
  echo "---- Copying ${parcel}"
  cp ${parcel} /opt/cloudera/parcel-repo/
  echo "---- Copying ${parcel}.sha"
  cp ${parcel}.sha /opt/cloudera/parcel-repo/
done

echo "-- Set CSDs and parcel repo permissions"
chown -R cloudera-scm:cloudera-scm /opt/cloudera/csd /opt/cloudera/parcel-repo
chmod 644 $(find /opt/cloudera/csd /opt/cloudera/parcel-repo -type f)

echo "-- Start CM, it takes about 2 minutes to be ready"
systemctl enable cloudera-scm-server
systemctl enable cloudera-scm-agent
systemctl start cloudera-scm-server

echo "-- Enable passwordless root login via rsa key"
ssh-keygen -f $KEY_FILE -t rsa -N ""
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat $KEY_FILE.pub >> ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys
ssh-keyscan -H $(hostname) >> ~/.ssh/known_hosts
sed -i 's/.*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
systemctl restart sshd

echo "-- Check for additional parcels"
chmod +x ${BASE_DIR}/check-for-parcels.sh

echo "-- Wait for CM to be ready before proceeding"
until $(curl --output /dev/null --silent --head --fail -u "admin:admin" http://localhost:7180/api/version); do
  echo "waiting 10s for CM to come up.."
  sleep 10
done
echo "-- CM has finished starting"

echo "-- Generate cluster template"
TEMPLATE_FILE=$BASE_DIR/cluster_template.${NAMESPACE}.json
export CDSW_DOMAIN=cdsw.${PUBLIC_IP}.nip.io
export CLUSTER_HOST=$(hostname -f)
export PRIVATE_IP=$(hostname -I | tr -d '[:space:]')
export DOCKER_DEVICE PUBLIC_DNS
python $BASE_DIR/cm_template.py --cdh-major-version $CDH_MAJOR_VERSION $CM_SERVICES > $TEMPLATE_FILE

echo "-- Create cluster"
CM_REPO_URL=$(grep baseurl $CM_REPO_FILE | sed 's/.*=//;s/ //g')
python $BASE_DIR/create_cluster.py $(hostname -f) $TEMPLATE_FILE $KEY_FILE $CM_REPO_URL

echo "-- Configure and start EFM"
retries=0
while true; do
  mysql -u efm -psupersecret1 < <( echo -e "drop database efm;\ncreate database efm;" )
  nohup service efm start &
  sleep 10
  set +e
  ps -ef | grep  efm.jar | grep -v grep
  cnt=$(ps -ef | grep  efm.jar | grep -v grep | wc -l)
  set -e
  if [ "$cnt" -gt 0 ]; then
    break
  fi
  if [ "$retries" == "5" ]; then
    break
  fi
  retries=$((retries + 1))
  echo "Retrying to start EFM ($retries)"
done

echo "-- Enable and start MQTT broker"
systemctl enable mosquitto
systemctl start mosquitto

echo "-- Copy demo files to a public directory"
mkdir -p /opt/demo
cp -f $BASE_DIR/simulate.py /opt/demo/
cp -f $BASE_DIR/spark.iot.py /opt/demo/
chmod -R 775 /opt/demo

echo "-- Start MiNiFi"
systemctl enable minifi
systemctl start minifi

# TODO: Implement Ranger DB and Setup in template
# TODO: Fix kafka topic creation once Ranger security is setup
if [[ ",${CM_SERVICES}," == *",KAFKA,"* ]]; then
  echo "-- Create Kafka topic (iot)"
  kafka-topics --zookeeper edge2ai-1.dim.local:2181/kafka --create --topic iot --partitions 10 --replication-factor 1
  kafka-topics --zookeeper edge2ai-1.dim.local:2181/kafka --describe --topic iot
fi

if [[ ",${CM_SERVICES}," == *",FLINK,"* ]]; then
  echo "-- Flink: extra workaround due to CSA-116"
  sudo -u hdfs hdfs dfs -chown flink:flink /user/flink
  sudo -u hdfs hdfs dfs -mkdir /user/${SSH_USER}
  sudo -u hdfs hdfs dfs -chown ${SSH_USER}:${SSH_USER} /user/${SSH_USER}

  echo "-- Runs a quick Flink WordCount to ensure everything is ok"
  echo "foo bar" > echo.txt
  export HADOOP_USER_NAME=flink
  hdfs dfs -put echo.txt
  flink run -sae -m yarn-cluster -p 2 /opt/cloudera/parcels/FLINK/lib/flink/examples/streaming/WordCount.jar --input hdfs:///user/$HADOOP_USER_NAME/echo.txt --output hdfs:///user/$HADOOP_USER_NAME/output
  hdfs dfs -cat hdfs:///user/$HADOOP_USER_NAME/output/*
  unset HADOOP_USER_NAME
fi

echo "-- At this point you can login into Cloudera Manager host on port 7180 and follow the deployment of the cluster"

# Finish install
