import groovy.json.JsonOutput
import groovy.json.JsonSlurperClassic

pipeline {
    agent any
    parameters {
        string(name: 'awsProfile', defaultValue: 'cicd', description: 'The AWS profile name to resolve credentials.')
        string(name: 'awsAccountNumber', defaultValue: '', description: 'The AWS account number to use.')
    }
    environment { 
        AWS_PROFILE = "${params.awsProfile}"
        AWS_ACCOUNT_NUMBER = "${params.awsAccountNumber}"
    }
    stages {
        stage('Build') {
            steps {
                sh 'make build-image'
            }
        }
        stage('EcrPush') {
            steps {
                script {
                    readProperties(file: 'Makefile.env').each { key, value -> env[key] = value }
                }
                sh '$(aws ecr get-login --no-include-email --registry-ids $AWS_ACCOUNT_NUMBER)'
                script {
                    def PUSH_RESULT = sh (
                    script: "make push-image",
                    returnStdout: true
                    ).trim()
                    echo "Push result: ${PUSH_RESULT}"
                }
            }
        }
        stage('SetEnvironment'){
            steps {
                script {
                    // This step reloads the env with configured values for account number and region in various values.
                    readProperties(file: 'Makefile.env').each { key, value -> tv = value.replace("AWS_ACCOUNT_NUMBER", env.AWS_ACCOUNT_NUMBER)
                                                                              env[key] = tv.replace("REGION", env.REGION)
                                                              }
                }
            }
        }
        stage('GetPrimaryTaskSet'){
            steps{
                script{
                    // Read all the TaskSets(deployments) for the cluster.
                    def describeClusterResult = sh (
                    script: "aws ecs describe-services --services $SERVICE_ARN --cluster $CLUSTER_ARN",
                    returnStdout: true
                    ).trim()
                    def clusterDetails = readJSON(text: describeClusterResult)
                    def primaryTaskSet = null
                    clusterDetails.services[0].taskSets.each { a -> 
                        if (a.status == "PRIMARY"){
                            primaryTaskSet = a
                        }
                    }
                    echo "The primary TaskSet is: ${primaryTaskSet}"

                    // Write the Primary TaskSet to file
                    def primaryTaskSetFile = env.TEMPLATE_BASE_PATH + '/' + env.PREVIOUS_PRIMARY_TASKSET_FILE
                    writeJSON(file: primaryTaskSetFile, json: primaryTaskSet, pretty: 2)
                }
            }
        }
        stage('RegisterTaskDefinition') {
            steps {
                sh 'printenv'
                script {
                    def newImage = sh (
                    script: "make latest_image",
                    returnStdout: true
                    ).trim()

                    def templateFile = env.TEMPLATE_BASE_PATH +'/' + TASK_DEF_TEMPLATE
                    def taskFamily = 'family'
                    if ( env.NEXT_ENV == 'Green'){
                        taskFamily = env.GREEN_TASK_FAMILY_PREFIX
                    }
                    else {
                        taskFamily = env.BLUE_TASK_FAMILY_PREFIX
                    }

                    def taskDefinitionTemplate = readJSON(file: templateFile)
                    taskDefinitionTemplate.family = taskFamily
                    taskDefinitionTemplate.taskRoleArn = env.TASK_ROLE_ARN
                    taskDefinitionTemplate.executionRoleArn = env.EXECUTION_ROLE_ARN
                    taskDefinitionTemplate.containerDefinitions[0].name = env.APP_NAME
                    taskDefinitionTemplate.containerDefinitions[0].image = newImage
                    taskDefinitionTemplate.containerDefinitions[0].portMappings[0].containerPort = env.APP_PORT.toInteger()
                    taskDefinitionTemplate.containerDefinitions[0].logConfiguration.options.'awslogs-group' = env.LOG_GROUP
                    taskDefinitionTemplate.containerDefinitions[0].logConfiguration.options.'awslogs-region' = env.REGION
                    taskDefFile = env.TEMPLATE_BASE_PATH + '/' + env.TASK_DEFINITION_FILE
                    writeJSON(file: taskDefFile, json: taskDefinitionTemplate)
                    
                    def registerTaskDefinitionOutput = sh (
                    script: "aws ecs register-task-definition --cli-input-json file://${taskDefFile}",
                    returnStdout: true
                    ).trim()
                    echo "Register Task Def result: ${registerTaskDefinitionOutput}"

                    def registerTaskDefOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.REGISTER_TASK_DEF_OUTPUT
                    writeJSON(file: registerTaskDefOutputFile, json: registerTaskDefinitionOutput, pretty: 2)
                }
            }
        }
        stage('CreateTaskSetTemplate') {
            steps{
                script{
                    def taskFamily = 'family'
                    def taskSetTemplateFile = env.TEMPLATE_BASE_PATH + '/' + env.TASK_SET_TEMPLATE_FILE
                    def taskSetFile = env.TEMPLATE_BASE_PATH + '/' + env.TASK_SET_FILE
                    def createTaskSetOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.CREATE_TASK_SET_OUTPUT
                    def targetGroupArn = 'tg'
                    def registerTaskDefOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.REGISTER_TASK_DEF_OUTPUT

                    if ( env.NEXT_ENV == 'Green' ){
                        taskFamily = env.GREEN_TASK_FAMILY_PREFIX
                        targetGroupArn = env.GREEN_TARGET_GROUP_ARN
                    }
                    else{
                        taskFamily = env.BLUE_TASK_FAMILY_PREFIX
                        targetGroupArn = env.BLUE_TARGET_GROUP_ARN
                    }

                    def registerTaskDefinitionOutput = readJSON(file: registerTaskDefOutputFile)
                    def taskSetTemplateJson = readJSON(file: taskSetTemplateFile)

                    def subnet_array = env.TASK_SUBNETS.split(',')
                    subnet_array.eachWithIndex { subnet, i -> 
                        taskSetTemplateJson.networkConfiguration.awsvpcConfiguration.subnets[i] = subnet
                    }
                    def sg_array = env.TASK_SECURITY_GROUPS.split(',')
                    sg_array.eachWithIndex { sg, i -> 
                        taskSetTemplateJson.networkConfiguration.awsvpcConfiguration.securityGroups[i] = sg
                    }

                    taskSetTemplateJson.taskDefinition = registerTaskDefinitionOutput.taskDefinition.taskDefinitionArn
                    taskSetTemplateJson.loadBalancers[0].containerPort = env.APP_PORT.toInteger()
                    taskSetTemplateJson.loadBalancers[0].targetGroupArn = targetGroupArn
                    writeJSON(file: taskSetFile, json: taskSetTemplateJson, pretty: 2)

                    // Register the task
                    def createTaskSetOutput = sh (
                    script: "aws ecs create-task-set --service $SERVICE_ARN --cluster $CLUSTER_ARN --cli-input-json file://${taskSetFile}",
                    returnStdout: true
                    ).trim()
                    echo "Create Task Set Result: ${createTaskSetOutput}"

                    writeJSON(file: createTaskSetOutputFile, json: createTaskSetOutput, pretty: 2)
                }
            }
        }
        stage('EnableTestListener'){
            steps{
                script{
                    def blueTG = null
                    def greenTG = null
                    if ( env.NEXT_ENV == 'Green' ){
                        blueTG = ["Weight": 0, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        greenTG = ["Weight": 100, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                    }
                    else{
                        blueTG = ["Weight": 100, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        greenTG = ["Weight": 0, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                    }
                    def tgs = [blueTG, greenTG]


                    def listenerDefaultActionsTemplate = """
                        {
                            "ListenerArn": "$env.TEST_LISTENER_ARN",
                            "DefaultActions": [
                                {
                                    "Type": "forward",
                                    "ForwardConfig": {
                                        "TargetGroups": ${JsonOutput.prettyPrint(JsonOutput.toJson(tgs))}
                                    }
                                }
                            ]
                        }
                    """
                    def testDefaultActionsFile = env.TEMPLATE_BASE_PATH + '/' + env.TEST_LISTENER_DEFAULT_ACTION_OUTPUT
                    
                    def listerDefaultActionJson = new JsonSlurperClassic().parseText(listenerDefaultActionsTemplate)

                    writeJSON(file: testDefaultActionsFile, json: listerDefaultActionJson, pretty: 2)

                    // Call the api to perform the swap
                    def modifyTestListenerResult = sh (
                    script: "aws elbv2 modify-listener --listener-arn $TEST_LISTENER_ARN --cli-input-json file://${testDefaultActionsFile}",
                    returnStdout: true
                    ).trim()
                    echo "The modify result: ${modifyTestListenerResult}"
                }
            }
        }
        stage ('WaitForTestingStage') {
            input {
                message "Ready to SWAP Live Listener?"
                ok "Yes, go ahead."
            }
            steps{
                echo "Moving on to perform SWAP ..................."
            }            
        }
        stage('SwapLive'){
            steps{
                script{
                    def liveBlueWeight = null
                    def liveGreenWeight = null
                    def testBlueWeight = null
                    def testGreenWeight = null
                    if ( env.NEXT_ENV == 'Green' ){
                        liveBlueWeight = ["Weight": 0, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        liveGreenWeight = ["Weight": 100, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                        testBlueWeight = ["Weight": 100, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        testGreenWeight = ["Weight": 0, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                    }
                    else{
                        liveBlueWeight = ["Weight": 100, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        liveGreenWeight = ["Weight": 0, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                        testBlueWeight = ["Weight": 0, "TargetGroupArn": env.BLUE_TARGET_GROUP_ARN]
                        testGreenWeight = ["Weight": 100, "TargetGroupArn": env.GREEN_TARGET_GROUP_ARN]
                    }
                    def tgs = [liveBlueWeight, liveGreenWeight]
                    def test_tgs = [testBlueWeight, testGreenWeight]

                    def liveListenerDefaultActionsTemplate = """
                        {
                            "ListenerArn": "$env.LIVE_LISTENER_ARN",
                            "DefaultActions": [
                                {
                                    "Type": "forward",
                                    "ForwardConfig": {
                                        "TargetGroups": ${JsonOutput.prettyPrint(JsonOutput.toJson(tgs))}
                                    }
                                }
                            ]
                        }
                    """
                    def testListenerDefaultActionsTemplate = """
                        {
                            "ListenerArn": "$env.TEST_LISTENER_ARN",
                            "DefaultActions": [
                                {
                                    "Type": "forward",
                                    "ForwardConfig": {
                                        "TargetGroups": ${JsonOutput.prettyPrint(JsonOutput.toJson(test_tgs))}
                                    }
                                }
                            ]
                        }
                    """

                    // Set live listener to new version
                    def liveDefaultActionsFile = env.TEMPLATE_BASE_PATH + '/' + env.LIVE_LISTENER_DEFAULT_ACTION_OUTPUT
                    def liveListerDefaultActionJson = new JsonSlurperClassic().parseText(liveListenerDefaultActionsTemplate)
                    writeJSON(file: liveDefaultActionsFile, json: liveListerDefaultActionJson, pretty: 2)
                    
                    def modifyLiveListenerResult = sh (
                    script: "aws elbv2 modify-listener --listener-arn $LIVE_LISTENER_ARN --cli-input-json file://${liveDefaultActionsFile}",
                    returnStdout: true
                    ).trim()
                    echo "The modify result: ${modifyLiveListenerResult}"

                    // Set test listener to previous version
                    def testDefaultActionsFile = env.TEMPLATE_BASE_PATH + '/' + env.TEST_LISTENER_DEFAULT_ACTION_OUTPUT
                    def testListerDefaultActionJson = new JsonSlurperClassic().parseText(testListenerDefaultActionsTemplate)
                    writeJSON(file: testDefaultActionsFile, json: testListerDefaultActionJson, pretty: 2)

                    def modifyTestListenerResult = sh (
                    script: "aws elbv2 modify-listener --listener-arn $TEST_LISTENER_ARN --cli-input-json file://${testDefaultActionsFile}",
                    returnStdout: true
                    ).trim()
                    echo "The modify result: ${modifyTestListenerResult}"
                }
            }
        }
        stage('UpdatePrimaryTaskSet'){
            steps{
                script{
                    def createTaskSetOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.CREATE_TASK_SET_OUTPUT
                    def upatePrimaryTaskSetOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.UPDATE_PRIMARY_TASK_SET_OUTPUT
                    def createTaskSetOutput = readJSON(file: createTaskSetOutputFile)

                    def updatePrimaryTaskSetOutput = sh (
                        script: "aws ecs update-service-primary-task-set --service $SERVICE_ARN --cluster $CLUSTER_ARN --primary-task-set ${createTaskSetOutput.taskSet.taskSetArn}",
                        returnStdout: true
                        ).trim()
                        echo "Upate Primary TaskSet Result: ${updatePrimaryTaskSetOutput}"
                        writeJSON(file: upatePrimaryTaskSetOutputFile, json: updatePrimaryTaskSetOutput, pretty: 2)
                }
            }
        }
        stage ('WaitForUserToDeletePreviousDeploymentStage') {
            input {
                message "***CAUTION***: Ready to DELETE previous deployment?"
                ok "Yes, go ahead."
            }
            steps{
                echo "Deleting previous deployment ..................."
            }            
        }
        stage('DeleteDeployment'){
            steps{
                script{
                    // Read the previous primary TaskSet from file
                    def primaryTaskSetFile = env.TEMPLATE_BASE_PATH + '/' + env.PREVIOUS_PRIMARY_TASKSET_FILE
                    def primaryTaskSetJson = readJSON(file: primaryTaskSetFile)

                    // Delete the TaskSet(deployment)
                    def deleteTaskSetOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.DELETE_TASK_SET_OUTPUT
                    def deleteTaskSetResult = sh (
                    script: "aws ecs delete-task-set --cluster $CLUSTER_ARN --service $SERVICE_ARN --task-set ${primaryTaskSetJson.id}",
                    returnStdout: true
                    ).trim()

                    writeJSON(file: deleteTaskSetOutputFile, json: deleteTaskSetResult, pretty: 2)
                    echo "Delete TaskSet: ${deleteTaskSetResult}"

                    // Deregister old TaskDefinition
                    def deregisterTaskDefOutputFile = env.TEMPLATE_BASE_PATH + '/' + env.DEREGISTER_TASK_DEF_OUTPUT
                    def deregisterTaskDefResult = sh (
                    script: "aws ecs deregister-task-definition --task-definition ${primaryTaskSetJson.taskDefinition}",
                    returnStdout: true
                    ).trim()

                    writeJSON(file: deregisterTaskDefOutputFile, json: deregisterTaskDefResult, pretty: 2)
                    echo "Deregister TaskDefinition: ${deregisterTaskDefResult}"
                }
            }
        }
    }
}