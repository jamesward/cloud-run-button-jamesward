#!/bin/bash

if [ ! -f "$KEY_FILE" ]; then
  echo "KEY_FILE must be set"
  exit 1
fi

if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
  echo "GOOGLE_CLOUD_PROJECT must be set"
  exit 1
fi

if [ -z "$GOOGLE_CLOUD_REGION" ]; then
  echo "GOOGLE_CLOUD_REGION must be set"
  exit 1
fi

if [ -z "$BUTTON_IMAGE" ]; then
  BUTTON_IMAGE="cloud-run-button"
fi

readonly GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
GIT_REMOTE="origin"

readonly GIT_FULLNAME=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)

if [ ! -z "$GIT_FULLNAME" ]; then
  GIT_REMOTE=$(echo "$GIT_FULLNAME" | cut -d"/" -f1)
fi

readonly GIT_URL=$(git remote get-url "$GIT_REMOTE")

readonly SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$SCRIPT_DIR"/.. || exit

docker build -f Dockerfile -t cloud-run-button .

function in_docker() {
  local CMD=$1
  docker run \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v $KEY_FILE:/root/user.json \
      -e GOOGLE_APPLICATION_CREDENTIALS=/root/user.json \
      --entrypoint=/bin/sh \
      "$BUTTON_IMAGE" \
      -c "gcloud config set survey/disable_prompts true && \
          gcloud auth activate-service-account --key-file=/root/user.json --quiet && \
          $CMD"
}

function run_test() {
  local DIR=$1
  local EXPECTED=$2
  local CLEAN=$3

  if [ "$CLEAN" != "false" ]; then
    in_docker "gcloud run services delete $DIR --platform=managed --project=$GOOGLE_CLOUD_PROJECT --region=$GOOGLE_CLOUD_REGION --quiet"
  fi

  echo "Running Cloud Run Button on $GIT_URL branch $GIT_BRANCH dir integration_tests/$DIR"

  in_docker "gcloud auth configure-docker --quiet && \
             /bin/cloudshell_open --project=$GOOGLE_CLOUD_PROJECT --region=$GOOGLE_CLOUD_REGION --repo_url=$GIT_URL --git_branch=$GIT_BRANCH --dir=integration_tests/$DIR"

  SERVICE_URL=$(in_docker "gcloud run services describe $DIR --project=$GOOGLE_CLOUD_PROJECT --region=$GOOGLE_CLOUD_REGION --platform=managed --format 'value(status.url)'")
}

function expect_body() {
  local DIR=$1
  local EXPECTED=$2
  local CLEAN=$3

  run_test "$DIR" "$EXPECTED" "$CLEAN"

  OUTPUT=$(curl -s $SERVICE_URL)

  if [ -n "$EXPECTED" ]; then
    printf "Output:\n$OUTPUT\n\n"
    printf "Expected:\n$EXPECTED\n\n"

    if [ "${OUTPUT#*$EXPECTED}" != "$OUTPUT" ] && [ ${#OUTPUT} -eq ${#EXPECTED} ]; then
      printf "Test passed!\n\n"
    else
      printf "Test failed!\n"
      exit 1
    fi
  fi
}

function expect_status() {
  local DIR=$1
  local EXPECTED=$2
  local CLEAN=$3

  run_test "$DIR" "$EXPECTED" "$CLEAN"

  local STATUS=$(curl -s -o /dev/null -w "%{http_code}" $SERVICE_URL)

  printf "Status: $STATUS\n"
  printf "Expected: $EXPECTED\n"

  if [ "$STATUS" -eq "$EXPECTED" ]; then
    printf "Test passed!\n\n"
  else
    printf "Test failed!\n"
    exit 1
  fi
}

expect_body "empty-appjson" "hello, world"

expect_body "hooks-prepostcreate-inline" "AB"

# precreate deploys (gen 1), sets GEN (gen 2), CRB deploys (gen 3), postcreate sets GEN (gen 4) but the env var GEN lags by 1 because deploying the GEN change creates a new gen
expect_body "hooks-prepostcreate-external" "3"
# the GEN should not change indicating that the precreate and postcreate did not run again since the service already exists
expect_body "hooks-prepostcreate-external" "3" "false"

# deploy an app that generates a secret and outputs it
expect_body "envvars-generated"
# check that on a subsequent deploy, the secret didn't change
expect_body "envvars-generated" "$OUTPUT" "false"

# todo: not sure how to do env vars that read stdin

expect_status "require-auth" "403"
