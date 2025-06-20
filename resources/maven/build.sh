#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke: initial configuration
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared

#####################
# Script init
#####################
set -eu

# execute script with bash if loaded with other shell interpreter
if [ -z "${BASH_VERSINFO:-}" ]; then /usr/bin/env bash "$0" "$@"; exit; fi

set -o pipefail # causes a pipeline to return the exit status of the last command in the pipe that returned a non-zero return value
set -o nounset # treat undefined variables as errors

# configure stack trace reporting
trap 'rc=$?; echo >&2 "$(date +%H:%M:%S) Error - exited with status $rc in [$BASH_SOURCE] at line $LINENO:"; cat -n $BASH_SOURCE | tail -n+$((LINENO - 3)) | head -n7' ERR

THIS_FILE_DIR=$(cd "$(dirname "$0")"; pwd -P)


#####################
# Main
#####################
RELEASE_TRIGGER_FILE=${RELEASE_TRIGGER_FILE:-.ci/release-trigger.sh}
if [[ -f $RELEASE_TRIGGER_FILE ]]; then
  echo "Sourcing [$RELEASE_TRIGGER_FILE]..."
  source "$RELEASE_TRIGGER_FILE"
else
  echo "File [$RELEASE_TRIGGER_FILE] is not present."
fi


echo
echo "###################################################"
echo "# Determining GIT branch......                    #"
echo "###################################################"
GIT_BRANCH=$(git branch --show-current)
echo "  -> GIT Branch: $GIT_BRANCH"


#
# set github author for commits during release and site builds
#
if [[ ${CAN_CREATE_RELEASE:-} == "true" && ${GITHUB_ACTIONS:-} == "true" ]]; then
  # https://github.community/t/github-actions-bot-email-address/17204
  git config --global user.name "github-actions[bot]"
  git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi


echo
source "$THIS_FILE_DIR/configure-maven.sh"


#
# decide whether to perform a release build or build+deploy a snapshot version
#
if [[ ${maven_project_version:-foo} == ${POM_CURRENT_VERSION:-bar} && ${CAN_CREATE_RELEASE:-} == "true" ]]; then
  # https://stackoverflow.com/questions/8653126/how-to-increment-version-number-in-a-shell-script/21493080#21493080
  nextDevelopmentVersion="$(echo ${POM_RELEASE_VERSION} | perl -pe 's/^((\d+\.)*)(\d+)(.*)$/$1.($3+1).$4/e')-SNAPSHOT"

  SKIP_TESTS=${SKIP_TESTS:-false}

  echo
  echo "###################################################"
  echo "# Creating Maven Release...                       #"
  echo "###################################################"
  echo "  ->          Release Version: ${POM_RELEASE_VERSION}"
  echo "  -> Next Development Version: ${nextDevelopmentVersion}"
  echo "  ->           Skipping Tests: ${SKIP_TESTS}"
  echo "  ->               Is Dry-Run: ${DRY_RUN}"

  # workaround for "No toolchain found with specification [version:11, vendor:default]" during release builds
  if [[ -f ${MAVEN_SETTINGS_FILE:-} ]]; then
    cp -f "${MAVEN_SETTINGS_FILE:-}" $HOME/.m2/settings.xml
  fi
  if [[ -f ${MAVEN_TOOLCHAINS_FILE:-} ]]; then
    cp -f "${MAVEN_TOOLCHAINS_FILE:-}" $HOME/.m2/toolchains.xml
  fi

  export DEPLOY_RELEASES_TO_MAVEN_CENTRAL=true

  $maven "$@" \
      -DskipTests=${SKIP_TESTS} \
      -DskipITs=${SKIP_TESTS} \
      -DdryRun=${DRY_RUN} \
      -Dresume=false \
      "-Darguments=-DskipTests=${SKIP_TESTS} -DskipITs=${SKIP_TESTS}" \
      -DreleaseVersion=${POM_RELEASE_VERSION} \
      -DdevelopmentVersion=${nextDevelopmentVersion} \
      help:active-profiles clean release:clean release:prepare release:perform \
      | grep -v -e "\[INFO\] Download.* from repository-restored-from-cache" `# suppress download messages from repo restored from cache ` \
      | grep -v -e "\[INFO\]  .* \[0.0[0-9][0-9]s\]" # the grep command suppresses all lines from maven-buildtime-extension that report plugins with execution time <=99ms
  exit $?
fi


#
# build/deploy snapshot version
#
if [[ ${CAN_CREATE_RELEASE:-} == "true" ]]; then
  maven_goal="deploy"

  if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then

    function initializeSiteBranch() {
      while [[ $# -gt 0 ]]; do
        case $1 in
          --branch)             local branch="$2";             shift 2 ;;
          --revert-last-commit) local revert_last_commit=true; shift 1 ;;
          *)                    echo "Unknown parameter: $1"; return 1 ;;
        esac
      done

      pushd /tmp
        rm -rf "$branch"
        github_repo_url="https://${GITHUB_USER}:${GITHUB_API_KEY}@github.com/${GITHUB_REPOSITORY}"
        if curl --output /dev/null --silent --head --fail "$github_repo_url/tree/$branch"; then
          git clone "$github_repo_url" --single-branch --branch "$branch" "$branch"
          pushd $branch >/dev/null
          if [[ "${revert_last_commit:-}" == "true" ]]; then
            git reset --hard HEAD^ # revert previous commit
          fi
        else
          git clone "$github_repo_url" "$branch"
          pushd $branch >/dev/null
          git checkout --orphan "$branch"
          git rm -rf .
          touch .gitkeep
          git add .gitkeep
          git commit -am "Initial commit"
        fi
        popd >/dev/null
      popd >/dev/null
    }

    last_commit_message=$(git log --pretty=format:"%s (%h)" -1)

    if [[ -n ${SNAPSHOTS_BRANCH:-} ]]; then
      echo
      echo "###################################################"
      echo "# Preparing $SNAPSHOTS_BRANCH branch...       #"
      echo "###################################################"
      initializeSiteBranch --branch $SNAPSHOTS_BRANCH
      maven_goal+=" -DaltSnapshotDeploymentRepository=temp-snapshots-repo::file:///tmp/$SNAPSHOTS_BRANCH/"
    fi

    if [[ -n ${JAVADOC_BRANCH:-} ]]; then
      echo
      echo "###################################################"
      echo "# Preparing $JAVADOC_BRANCH branch...            #"
      echo "###################################################"
      initializeSiteBranch --branch $JAVADOC_BRANCH --revert-last-commit
      rm -rf target/*-javadoc.jar target/reports/apidocs
      maven_goal+=" -Dskip.maven.javadoc=false"
    fi
  fi
else
  maven_goal="verify"
fi


echo
echo "###################################################"
echo "# Building Maven Project...                       #"
echo "###################################################"
$maven "$@" \
    help:active-profiles clean $maven_goal \
    | grep -v -e "\[INFO\] Download.* from repository-restored-from-cache" `# suppress download messages from repo restored from cache ` \
    | grep -v -e "\[INFO\]  .* \[0.0[0-9][0-9]s\]" # the grep command suppresses all lines from maven-buildtime-extension that report plugins with execution time <=99ms

if [[ ${CAN_CREATE_RELEASE:-} == "true" && ${GITHUB_ACTIONS:-} == "true" ]]; then
  if [[ -n ${SNAPSHOTS_BRANCH:-} ]]; then
    echo
    echo "###################################################"
    echo "# Update Maven Snapshots Repo...                  #"
    echo "###################################################"
    pushd /tmp/$SNAPSHOTS_BRANCH >/dev/null
      cat <<EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <title>${GITHUB_REPOSITORY} - Maven Snapshots Repo</title>
</head>
<body>
  <h1>${GITHUB_REPOSITORY} - Maven Snapshots Repo</h1>
</body>
</html>
EOF
      if [[ $(git -C . ls-files -o -m -d --exclude-standard | wc -l) -gt 0 ]]; then
        git add --all
        git commit -am "$maven_project_version: $last_commit_message"
        git push origin $SNAPSHOTS_BRANCH --force
      fi
    popd >/dev/null
  fi

  if [[ -n ${JAVADOC_BRANCH:-} ]]; then
    echo
    echo "###################################################"
    echo "# Deploying Javadoc...                            #"
    echo "###################################################"
    rm -rf /tmp/$JAVADOC_BRANCH/javadoc
    if [[ -f target/reports/apidocs/index.html ]]; then
      mv target/reports/apidocs /tmp/$JAVADOC_BRANCH/javadoc
    else
      mkdir /tmp/$JAVADOC_BRANCH/javadoc
      unzip "target/*-javadoc.jar" -d /tmp/$JAVADOC_BRANCH/javadoc
    fi
    pushd /tmp/$JAVADOC_BRANCH >/dev/null
      cat <<EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta http-equiv="refresh" content="0; url=/${GITHUB_REPOSITORY##*/}/javadoc/" />
  <title>Redirecting...</title>
</head>
<body>
  <p>If you are not redirected automatically, follow this <a href="/javadoc/">link to the /${GITHUB_REPOSITORY##*/}javadoc/</a>.</p>
</body>
</html>
EOF
      if [[ $(git -C . ls-files -o -m -d --exclude-standard | wc -l) -gt 0 ]]; then
        git add --all
        git commit -am "$maven_project_version: $last_commit_message"
        git push origin $JAVADOC_BRANCH --force
      fi
    popd >/dev/null
  fi
fi
