#!/usr/bin/env bash
set -euo pipefail

: "${S3A_ENDPOINT:?S3A_ENDPOINT must be set}"

AWS_ACCESS_KEY_ID="hadoopS3aAccessKey01"
AWS_SECRET_ACCESS_KEY="hadoopS3aSecretKey0000000000000000000000"
HADOOP_S3A_BUCKET="s3a-test"

# As downloading the hadoop repository and pre-downloading the dependencies takes a long time, we do it in a separate step in the Dockerfile, and then we just run the tests in this script.
# This way, we can take advantage of Docker caching and avoid re-downloading the dependencies every time we want to run the tests.
# apt-get update -y
# apt-get install -y git
# git clone --depth 1 --branch "${HADOOP_S3A_BRANCH}" https://github.com/apache/hadoop.git /tmp/hadoop
# mkdir -p /tmp/hadoop/hadoop-tools/hadoop-aws/src/test/resources
cat <<EOF > src/test/resources/auth-keys.xml
<configuration>
  <property>
    <name>fs.s3a.endpoint</name>
    <value>${S3A_ENDPOINT}</value>
  </property>
  <property>
    <name>fs.s3a.connection.ssl.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>fs.s3a.path.style.access</name>
    <value>true</value>
  </property>
  <property>
    <name>fs.s3a.aws.credentials.provider</name>
    <value>org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider</value>
  </property>
  <property>
    <name>fs.s3a.access.key</name>
    <value>${AWS_ACCESS_KEY_ID}</value>
  </property>
  <property>
    <name>fs.s3a.secret.key</name>
    <value>${AWS_SECRET_ACCESS_KEY}</value>
  </property>
  <property>
    <name>fs.s3a.region</name>
    <value>us-east-1</value>
  </property>
  <property>
    <name>test.fs.s3a.name</name>
    <value>s3a://${HADOOP_S3A_BUCKET}/</value>
  </property>
  <property>
    <name>test.fs.s3a.bucket</name>
    <value>${HADOOP_S3A_BUCKET}</value>
  </property>
  <property>
    <name>fs.s3a.bucket</name>
    <value>${HADOOP_S3A_BUCKET}</value>
  </property>
  <property>
    <name>fs.contract.test.fs.s3a</name>
    <value>s3a://${HADOOP_S3A_BUCKET}/</value>
  </property>
  <property>
    <name>test.fs.s3a.encryption.enabled</name>
    <value>false</value>
  </property>
   <property>
    <name>test.fs.s3a.create.storage.class.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>test.fs.s3a.sts.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>test.fs.s3a.create.acl.enabled</name>
    <value>false</value>
  </property>
  <property>
    <name>test.fs.s3a.performance.enabled</name>
    <value>false</value>
  </property>
  <!--
   If the store reports errors when trying to list/abort completed multipart uploads,
   expect failures in ITestUploadRecovery and ITestS3AContractMultipartUploader.
   The tests can be reconfigured to expect failure.
   Note how this can be set as a per-bucket option.
  -->
  <property>
    <name>fs.s3a.ext.test.multipart.commit.consumes.upload.id</name>
    <value>true</value>
  </property>
</configuration>
EOF

EXCLUDED_ITESTS="${EXCLUDED_ITESTS:-ITestS3AContractMultipartUploader}" # TODO: remove exclusion after CI resource fix
echo "Running: mvn -pl :hadoop-aws -am -DskipTests=false -DskipITs=false -Dit.test='ITestS3A*,!${EXCLUDED_ITESTS}' -Dtest=TestS3A* verify"
set +e
mvn -pl :hadoop-aws -am -DskipTests=false -DskipITs=false "-Dit.test=ITestS3A*,!${EXCLUDED_ITESTS}" -Dtest=TestS3A* verify
mvn_status=$?
set -e

# Failsafe may log failures and still exit 0 (BUILD SUCCESS). Inspect reports on disk.
FAILSAFE_REPORTS="target/failsafe-reports"
FAILSAFE_SUMMARY="${FAILSAFE_REPORTS}/failsafe-summary.xml"
failsafe_failed=0
if [ -f "$FAILSAFE_SUMMARY" ]; then
  if ! grep -qE '<failsafe-summary[^>]*result="0"' "$FAILSAFE_SUMMARY" \
    || grep -qE '<(failures|errors)>[1-9][0-9]*</(failures|errors)>' "$FAILSAFE_SUMMARY"; then
    failsafe_failed=1
  fi
elif compgen -G "${FAILSAFE_REPORTS}/TEST-*.xml" >/dev/null 2>&1; then
  if grep -hE ' failures="[1-9][0-9]*"| errors="[1-9][0-9]*"' "${FAILSAFE_REPORTS}"/TEST-*.xml 2>/dev/null | grep -q .; then
    failsafe_failed=1
  fi
fi
if [ "$failsafe_failed" -eq 1 ]; then
  exit 1
fi
if [ "$mvn_status" -ne 0 ]; then
  exit "$mvn_status"
fi
