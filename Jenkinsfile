@Library('homelab-shared-lib') _

// Release pipeline for pion_bridge (see RELEASING.md). Run it by hand after
// pushing a version bump in pubspec.yaml and its CHANGELOG.md section to master.
//
// It runs the host test layers and builds every platform's native binaries in
// parallel (Android/Linux/Windows in a Docker container on dileant, macOS/iOS in
// a disposable Tart VM on mini), then publishes them as GitHub Release
// v<version>; publishing is what creates the tag, on exactly the commit that was
// tested and built. Until that last step succeeds nothing is tagged or public:
// a failed run leaves at most a draft release, which the next run replaces.

@NonCPS
def pubspecVersion(String pubspec) {
    def m = pubspec =~ /(?m)^version:[ \t]*([^+\s]+)/
    return m.find() ? m.group(1) : null
}

// Every stage works on the commit Prepare resolved, even if master moves mid-run.
def checkoutReleaseCommit() {
    deleteDir()
    checkout scm
    sh "git checkout -q --detach ${env.PB_COMMIT}"
}

// Runs a command in the builder image with the workspace mounted. Named volumes
// keep Go and pub caches warm between runs.
def inBuilder(String command) {
    withEnv(["PB_COMMAND=${command}"]) {
        sh '''
            docker run --rm \
                -e PB_COMMAND -e PB_VERSION -e PB_COMMIT -e GH_TOKEN \
                -v "$WORKSPACE":/workspace -w /workspace \
                -v pion-bridge-go-mod:/root/go/pkg/mod \
                -v pion-bridge-go-build:/root/.cache/go-build \
                -v pion-bridge-pub-cache:/root/.pub-cache \
                pion-bridge-builder:latest bash -c "$PB_COMMAND"
        '''
    }
}

pipeline {
    agent none

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
        skipDefaultCheckout()
    }

    parameters {
        booleanParam(name: 'DRAFT_ONLY', defaultValue: false,
                     description: 'Build and upload everything to a draft GitHub release, but do not publish it (no tag). The next run replaces the draft.')
    }

    stages {
        stage('Prepare') {
            agent { label 'linux && docker' }
            steps {
                checkout scm
                script {
                    env.PB_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    env.PB_VERSION = pubspecVersion(readFile('pubspec.yaml'))
                    if (!env.PB_VERSION) {
                        error 'No version: line in pubspec.yaml'
                    }
                    currentBuild.displayName = "#${env.BUILD_NUMBER} · ${env.PB_VERSION}"
                }
                echo "Releasing pion_bridge ${env.PB_VERSION} from ${env.PB_COMMIT}"
                sh 'docker build -t pion-bridge-builder:latest tooling/ci/linux'
                withCredentials([usernamePassword(credentialsId: 'gurupras-jenkins-ci-cd',
                                                  usernameVariable: 'GH_APP_ID',
                                                  passwordVariable: 'GH_TOKEN')]) {
                    inBuilder('python3 tooling/ci/publish_github_release.py check --version "$PB_VERSION"')
                }
            }
        }

        stage('Test and build') {
            parallel {
                stage('Test') {
                    agent { label 'linux && docker' }
                    steps {
                        checkoutReleaseCommit()
                        inBuilder('bash tooling/ci/test.sh')
                    }
                }

                stage('Android, Linux, Windows') {
                    agent { label 'linux && docker' }
                    steps {
                        checkoutReleaseCommit()
                        inBuilder('bash tooling/ci/linux/build.sh')
                        stash name: 'dist-linux', includes: 'dist/*.tar.gz'
                    }
                }

                stage('macOS, iOS') {
                    agent { label 'macos && tart' }
                    steps {
                        script {
                            macosBuildVM {
                                checkoutReleaseCommit()
                                sh 'bash tooling/ci/macos/build.sh'
                                stash name: 'dist-apple', includes: 'dist/*.tar.gz'
                            }
                        }
                    }
                }
            }
        }

        stage('Publish') {
            agent { label 'linux && docker' }
            steps {
                checkoutReleaseCommit()
                unstash 'dist-linux'
                unstash 'dist-apple'
                withCredentials([usernamePassword(credentialsId: 'gurupras-jenkins-ci-cd',
                                                  usernameVariable: 'GH_APP_ID',
                                                  passwordVariable: 'GH_TOKEN')]) {
                    inBuilder('python3 tooling/ci/publish_github_release.py publish --version "$PB_VERSION" --commit "$PB_COMMIT"' +
                              (params.DRAFT_ONLY ? ' --draft-only' : ''))
                }
                archiveArtifacts artifacts: 'dist/*', fingerprint: true
            }
        }
    }
}
