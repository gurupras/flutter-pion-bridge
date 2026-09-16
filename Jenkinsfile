@Library('homelab-shared-lib') _

// Build, e2e-test and release pion_bridge. See RELEASING.md.
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
// Releases need no button: a push to master whose pubspec.yaml version is not yet
// tagged is released once every stage above passes — the Publish stage uploads the
// archives to a draft GitHub Release and publishes it, which creates the
// v<version> tag on exactly the commit that was tested. Any other push just builds
// and tests. A failed run tags nothing and leaves at most a draft, which the next
// run replaces, so recovering is another push.

@NonCPS
def pubspecVersion(String pubspec) {
    def m = pubspec =~ /(?m)^version:[ \t]*([^+\s]+)/
    return m.find() ? m.group(1) : null
}

// Every stage works on the commit Prepare resolved, even if master moves mid-run.
//
// The disposable VMs clone over the network into an empty disk, where this
// repository's history costs tens of minutes; they take a shallow copy, which
// still contains PB_COMMIT because it is the tip Prepare just read. The
// containers on dileant clone locally in seconds, so they keep full history.
def checkoutRunCommit(Map opts = [:]) {
    deleteDir()
    if (opts.shallow) {
        checkout([$class: 'GitSCM',
                  branches: [[name: env.PB_COMMIT]],
                  userRemoteConfigs: [[url: 'https://github.com/gurupras/flutter-pion-bridge.git']],
                  extensions: [[$class: 'CloneOption', shallow: true, depth: 20, noTags: true, honorRefspec: true]]])
    } else {
        checkout scm
    }
    if (isUnix()) {
        sh "git checkout -q --detach ${env.PB_COMMIT}"
    } else {
        bat "git checkout -q --detach ${env.PB_COMMIT}"
    }
}

// Runs a command in the builder image with the workspace mounted. Named volumes
// keep Go, pub and Gradle caches warm between runs.
def inBuilder(Map opts = [:], String command) {
    def dockerArgs = opts.dockerArgs ?: ''
    withEnv(["PB_COMMAND=${command}", "PB_DOCKER_ARGS=${dockerArgs}"]) {
        return sh(returnStatus: opts.returnStatus ?: false, script: '''
            docker run --rm $PB_DOCKER_ARGS \
                -e PB_COMMAND -e PB_VERSION -e PB_COMMIT -e GH_TOKEN \
                -v "$WORKSPACE":/workspace -w /workspace \
                -v pion-bridge-go-mod:/root/go/pkg/mod \
                -v pion-bridge-go-build:/root/.cache/go-build \
                -v pion-bridge-pub-cache:/root/.pub-cache \
                -v pion-bridge-gradle:/root/.gradle \
                pion-bridge-builder:latest bash -c "$PB_COMMAND"
        ''')
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
                }
                sh 'docker build -t pion-bridge-builder:latest tooling/ci/linux'
                script {
                    // Release only master, and only when the version in
                    // pubspec.yaml has no tag yet: check exits 3 for a version
                    // that is already out (an ordinary push), 0 when this push
                    // bumped it, and non-zero on a real problem such as a
                    // missing changelog entry.
                    def branch = env.BRANCH_NAME ?: 'master'
                    env.PB_RELEASE = 'false'
                    if (branch == 'master') {
                        githubToken {
                            def status = inBuilder(returnStatus: true,
                                'python3 tooling/ci/publish_github_release.py check --version "$PB_VERSION"')
                            if (status == 0) {
                                env.PB_RELEASE = 'true'
                            } else if (status != 3) {
                                error "release check failed (exit ${status})"
                            }
                        }
                    }
                    currentBuild.displayName = "#${env.BUILD_NUMBER} · ${env.PB_VERSION}" +
                        (env.PB_RELEASE == 'true' ? ' · release' : '')
                }
                echo "pion_bridge ${env.PB_VERSION} at ${env.PB_COMMIT}, release=${env.PB_RELEASE}"
            }
        }

        stage('Build and test') {
            parallel {
                stage('Host tests') {
                    agent { label 'linux && docker' }
                    options { timeout(time: 30, unit: 'MINUTES') }
                    steps {
                        checkoutRunCommit()
                        inBuilder('bash tooling/ci/test.sh')
                    }
                }

                stage('Android, Linux, Windows') {
                    agent { label 'linux && docker' }
                    options { timeout(time: 60, unit: 'MINUTES') }
                    steps {
                        checkoutRunCommit()
                        inBuilder('bash tooling/ci/linux/build.sh')
                        stash name: 'dist-linux', includes: 'dist/*.tar.gz'
                        inBuilder('bash tooling/ci/e2e/linux.sh')
                        inBuilder(dockerArgs: '--device /dev/kvm', 'bash tooling/ci/e2e/android.sh')
                    }
                }

                stage('macOS, iOS') {
                    agent { label 'macos && tart' }
                    options { timeout(time: 60, unit: 'MINUTES') }
                    steps {
                        script {
                            macosBuildVM {
                                checkoutRunCommit(shallow: true)
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
            options { timeout(time: 45, unit: 'MINUTES') }
            steps {
                script {
                    windowsBuildVM {
                        checkoutRunCommit(shallow: true)
                        unstash 'dist-linux'
                        powershell '& tooling/ci/e2e/windows.ps1'
                    }
                }
            }
        }

        stage('Publish') {
            when { expression { return env.PB_RELEASE == 'true' } }
            agent { label 'linux && docker' }
            steps {
                checkoutRunCommit()
                unstash 'dist-linux'
                unstash 'dist-apple'
                githubToken {
                    inBuilder('python3 tooling/ci/publish_github_release.py publish --version "$PB_VERSION" --commit "$PB_COMMIT"')
                }
                archiveArtifacts artifacts: 'dist/*', fingerprint: true
            }
        }
    }
}
