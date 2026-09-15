@Library('homelab-shared-lib') _

// Build, e2e-test and (optionally) release pion_bridge. See RELEASING.md.
//
// Every run builds all platforms' native binaries from one commit and runs the
// example app's e2e test against the packaged archives — the files a release
// would ship — on every platform and in every bridge mode it has:
//   Android, Linux, Windows  built in a Docker container on dileant; Linux and
//                            an Android emulator tested in that container,
//                            Windows in a disposable KVM VM
//   macOS, iOS               built and tested (desktop + simulator) in a
//                            disposable Tart VM on mini
// plus the host test layers.
//
// PUBLISH=none (default) stops there. draft/release then upload the archives to
// a GitHub Release v<version> (draft leaves it unpublished); publishing is what
// creates the tag, on exactly the commit that was tested and built. A failed
// run tags nothing and leaves at most a draft, which the next run replaces.

@NonCPS
def pubspecVersion(String pubspec) {
    def m = pubspec =~ /(?m)^version:[ \t]*([^+\s]+)/
    return m.find() ? m.group(1) : null
}

// Every stage works on the commit Prepare resolved, even if master moves mid-run.
def checkoutRunCommit() {
    deleteDir()
    checkout scm
    if (isUnix()) {
        sh "git checkout -q --detach ${env.PB_COMMIT}"
    } else {
        bat "git checkout -q --detach ${env.PB_COMMIT}"
    }
}

// Runs a command in the builder image with the workspace mounted. Named volumes
// keep Go, pub and Gradle caches warm between runs.
def inBuilder(String command, String dockerArgs = '') {
    withEnv(["PB_COMMAND=${command}", "PB_DOCKER_ARGS=${dockerArgs}"]) {
        sh '''
            docker run --rm $PB_DOCKER_ARGS \
                -e PB_COMMAND -e PB_VERSION -e PB_COMMIT -e GH_TOKEN \
                -v "$WORKSPACE":/workspace -w /workspace \
                -v pion-bridge-go-mod:/root/go/pkg/mod \
                -v pion-bridge-go-build:/root/.cache/go-build \
                -v pion-bridge-pub-cache:/root/.pub-cache \
                -v pion-bridge-gradle:/root/.gradle \
                pion-bridge-builder:latest bash -c "$PB_COMMAND"
        '''
    }
}

def githubToken(Closure body) {
    withCredentials([usernamePassword(credentialsId: 'gurupras-jenkins-ci-cd',
                                      usernameVariable: 'GH_APP_ID',
                                      passwordVariable: 'GH_TOKEN')]) {
        body()
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
        choice(name: 'PUBLISH', choices: ['none', 'draft', 'release'],
               description: 'none: build and test only. draft: also upload a draft GitHub release (no tag). release: publish GitHub Release v<pubspec version>, creating the tag.')
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
                    currentBuild.displayName = "#${env.BUILD_NUMBER} · ${env.PB_VERSION} · ${params.PUBLISH}"
                }
                echo "pion_bridge ${env.PB_VERSION} at ${env.PB_COMMIT}, PUBLISH=${params.PUBLISH}"
                sh 'docker build -t pion-bridge-builder:latest tooling/ci/linux'
                script {
                    if (params.PUBLISH != 'none') {
                        githubToken {
                            inBuilder('python3 tooling/ci/publish_github_release.py check --version "$PB_VERSION"')
                        }
                    }
                }
            }
        }

        stage('Build and test') {
            parallel {
                stage('Host tests') {
                    agent { label 'linux && docker' }
                    steps {
                        checkoutRunCommit()
                        inBuilder('bash tooling/ci/test.sh')
                    }
                }

                stage('Android, Linux, Windows') {
                    agent { label 'linux && docker' }
                    steps {
                        checkoutRunCommit()
                        inBuilder('bash tooling/ci/linux/build.sh')
                        stash name: 'dist-linux', includes: 'dist/*.tar.gz'
                        inBuilder('bash tooling/ci/e2e/linux.sh')
                        inBuilder('bash tooling/ci/e2e/android.sh', '--device /dev/kvm')
                    }
                }

                stage('macOS, iOS') {
                    agent { label 'macos && tart' }
                    steps {
                        script {
                            macosBuildVM {
                                checkoutRunCommit()
                                sh 'bash tooling/ci/macos/build.sh'
                                stash name: 'dist-apple', includes: 'dist/*.tar.gz'
                                sh 'bash tooling/ci/e2e/apple.sh macos'
                                sh 'bash tooling/ci/e2e/apple.sh ios'
                            }
                        }
                    }
                }
            }
        }

        stage('Windows e2e') {
            agent { label 'windows && kvm' }
            steps {
                script {
                    windowsBuildVM {
                        checkoutRunCommit()
                        unstash 'dist-linux'
                        powershell '& tooling/ci/e2e/windows.ps1'
                    }
                }
            }
        }

        stage('Publish') {
            when { expression { return params.PUBLISH != 'none' } }
            agent { label 'linux && docker' }
            steps {
                checkoutRunCommit()
                unstash 'dist-linux'
                unstash 'dist-apple'
                githubToken {
                    inBuilder('python3 tooling/ci/publish_github_release.py publish --version "$PB_VERSION" --commit "$PB_COMMIT"' +
                              (params.PUBLISH == 'draft' ? ' --draft-only' : ''))
                }
                archiveArtifacts artifacts: 'dist/*', fingerprint: true
            }
        }
    }
}
