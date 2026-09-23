pipeline {
	agent none
	stages {
		stage('Build and push image') {

			agent {
				node {
				label 'docker'
				}
			}
			steps {
				script {
					checkout scm

					dir('docker/ci') { 
						app = docker.build(
							"cubridci/cubridci",
							"--build-arg CUBRID_3RDPARTY_REVISION=ab0cfa19e25853345eee6f4e2de1fc537f266d9a " +
							"--build-arg CUBRID_3RDPARTY_FINGERPRINT=b797d7a5b0c38d0cc67f4ccba5e14d8b3b62639f909c6f7c3b348b89509e3647 ."
						)
					}

					docker.withRegistry('', 'docker-hub') {
						app.push("${env.BRANCH_NAME}")
					}
					
					sh "docker rmi cubridci/cubridci:${env.BRANCH_NAME}"
				}
			}
		}
	}
}
