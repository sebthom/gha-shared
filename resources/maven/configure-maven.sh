#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © Sebastian Thomschke
# SPDX-FileContributor: Sebastian Thomschke: initial configuration
# SPDX-License-Identifier: MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/sebthom/gha-shared

# Usage: source this file before invoking mvn so all variables are configured.
#
# When sourced this script:
#   • Sets (shell variables, not automatically exported):
#     – $maven - the Maven command to invoke (either the local wrapper `./mvnw` or `mvn` on the PATH) including default options
#     – $maven_project_version - the project's version string read from the `<version>` element in `pom.xml`
#
#   • Exports:
#     – MAVEN_OPTS - JVM options for Maven invocations (heap settings, headless mode, security/IPv4 prefs)
#
#   • If running under GitHub Actions:
#     – Writes maven_project_version to $GITHUB_ENV so later steps can consume the project version
#
#   • If a specific Maven version must be installed (wrapper not on PATH):
#     – Sets and exports M2_HOME
#     – Prepends PATH with $M2_HOME/bin so that the downloaded Maven is used
if ! (return 0 2>/dev/null); then # https://stackoverflow.com/a/28776166/5116073
  echo "${BASH_SOURCE[0]}: This file must be sourced"'!'" See the 'source' command."
  false
else
  echo "###################################################"
  echo "# Ensuring Maven is available...                  #"
  echo "###################################################"
  if [[ ${MAVEN_VERSION:-mvnw} == "mvnw" ]]; then
    maven=./mvnw
    if [[ -f ./mvnw ]]; then
      echo "Using Maven Wrapper"
      chmod u+x ./mvnw
    else
      echo "❌ Usage of Maven wrapper requested but file [./mvnw] does not exist"
      exit 1
    fi
  else
    maven=mvn

    if command -v mvn >/dev/null; then
      current_maven_version="$(mvn -v | awk '/Apache Maven/{print $3}')"
      echo "Detected Maven $current_maven_version on PATH"
    else
      echo "No Maven installation detected on PATH"
    fi

    if [[ ${MAVEN_VERSION} == "latest" ]]; then
      echo "Determining latest Maven version..."
      latest_maven_version=$(
        curl -sSf https://repo1.maven.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml |
        # extract only numeric-dot versions from each <version>...</version> tag (no -alpha, -beta, -rc, ...)
        sed -nE 's|.*<version>([0-9]+(\.[0-9]+)*)</version>.*|\1|p' |
        # numeric sort, take the last line -> highest stable version
        sort -V | tail -1
      )
      echo "  -> Latest Maven Version: ${latest_maven_version}"

      if [[ ${current_maven_version:-} != "$latest_maven_version" ]]; then
        install_maven_version="$latest_maven_version"
      else
        echo "Current Maven is already the latest; nothing to do."
      fi
    else   # a specific version was requested
      if [[ ${current_maven_version:-} != "$MAVEN_VERSION" ]]; then
        install_maven_version="$current_maven_version"
      else
        echo "Requested Maven $MAVEN_VERSION is already installed; nothing to do."
      fi
    fi

    if [[ -n ${install_maven_version:-} ]]; then
      echo "Installing Maven $install_maven_version ..."
      if [[ ! -f $HOME/.m2/bin/apache-maven-$install_maven_version/bin/mvn ]]; then
        mkdir -p "$HOME/.m2/bin"
        rm -rf "$HOME/.m2/bin/apache-maven-$install_maven_version"
        #maven_download_url="https://dlcdn.apache.org/maven/maven-3/$install_maven_version/binaries/apache-maven-${install_maven_version}-bin.tar.gz"
        maven_download_url="https://repo1.maven.org/maven2/org/apache/maven/apache-maven/$install_maven_version/apache-maven-${install_maven_version}-bin.tar.gz"
        echo "Downloading [$maven_download_url]..."
        curl -fsSL "$maven_download_url" | tar zx -C "$HOME/.m2/bin/"
      fi
      export M2_HOME="$HOME/.m2/bin/apache-maven-$install_maven_version"
      export PATH="$M2_HOME/bin:$PATH"
      echo "Maven $install_maven_version installed at $M2_HOME"
    fi
    unset \
      current_maven_version \
      install_maven_version \
      maven_download_url \
      latest_maven_version
  fi

  echo
  echo "###################################################"
  echo "# Configuring MAVEN_OPTS...                       #"
  echo "###################################################"
  MAVEN_OPTS="${MAVEN_OPTS:-}"
  MAVEN_OPTS+=" -Djava.security.egd=file:/dev/./urandom" # https://stackoverflow.com/questions/58991966/what-java-security-egd-option-is-for/59097932#59097932
  MAVEN_OPTS+=" -Dorg.slf4j.simpleLogger.showDateTime=true -Dorg.slf4j.simpleLogger.dateTimeFormat=HH:mm:ss,SSS" # https://stackoverflow.com/questions/5120470/how-to-time-the-different-stages-of-maven-execution/49494561#49494561
  MAVEN_OPTS+=" -Xmx1024m -Djava.awt.headless=true -Djava.net.preferIPv4Stack=true -Dhttps.protocols=TLSv1.3,TLSv1.2"
  echo "  -> MAVEN_OPTS: $MAVEN_OPTS"
  export MAVEN_OPTS

  maven+=" --errors --update-snapshots --batch-mode --show-version"
  if [[ -f ${MAVEN_SETTINGS_FILE:-} ]]; then
    maven+=" -s $MAVEN_SETTINGS_FILE"
  fi
  if [[ -f ${MAVEN_TOOLCHAINS_FILE:-} ]]; then
    maven+=" -t $MAVEN_TOOLCHAINS_FILE"
  fi
  if [[ -n ${GITEA_ACTIONS:-} || (-n ${CI:-} && -z ${ACT:-}) ]]; then  # if running on a remote CI but not on local nektos/act runner
    maven+=" --no-transfer-progress"
  fi
  if [[ -n ${ACT:-} && -z ${GITEA_ACTIONS:-} ]]; then # when executed by local nektos/act
    maven+=" -Dformatter.validate.lineending=KEEP"
    maven+=" -Djgit.dirtyWorkingTree=warning"
  fi
  if [[ ${CAN_CREATE_RELEASE:-} == "true" && ${GITHUB_ACTIONS:-} == "true" ]]; then
    maven+=" -Dskip.maven.javadoc=false"
  fi
  echo "  -> maven: $maven"


  echo
  echo "###################################################"
  echo "# Determining Maven project version...            #"
  echo "###################################################"
  maven_project_version=$(python <<'EOF'
import xml.etree.ElementTree as ET
root = ET.parse("pom.xml").getroot()
version = root.find("{http://maven.apache.org/POM/4.0.0}version")
if version is None:
    raise RuntimeError("Could not find <version> in pom.xml")
print(version.text)
EOF
)
  echo "  -> Current Version: $maven_project_version"
  if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
    echo "MAVEN_PROJECT_VERSION=$maven_project_version" >> $GITHUB_ENV
  fi
fi
