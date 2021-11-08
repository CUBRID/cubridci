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
						app = docker.build("cubridci/cubridci")
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
