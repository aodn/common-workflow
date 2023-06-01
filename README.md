# common-workflow

> :exclamation: This repo contains common work that being call by other repo, please take caution when modify the yaml.

## Directory
|  Directory | Description |
| --- | ---- |
| .github/workflows | common workflow files |
| dockers | pre-defined docker files from DevOps, other repo can use this to achive standard container build |
---
## Samples
Below provide few sample for other repo to copy and use, feel free to modify if it didn't fit.

```yaml
name: Template build and deploy job
# Limited which branch to build, the common workflow use gitversion to generate the next
# version number. 
#
# Details: https://gitversion.net/docs/, we use the GitHubFlow not GitFlow
on:
  push:
    branches:
      # GitHubFlow use this convention (feature/*) for any branch from main, but this flow
      # still work even if you do not follow, but your deploy branch must call main / master
      - feature/*    
      - main
      - master

jobs:
  build-upload:
    uses: aodn/common-workflow/.github/workflows/build-with-docker.yaml@main
    with:
      # Your artifact name, change it
      artifact: ogcapi-java
      # Your build container docker file name, located in root directory of repo
      docker_file: Docker.build
      # The command you kick-start the build, change it
      cmd: mvn -f ogc-api clean package
      # Your output file path and name, change it
      target: ogc-api/target/ogc-api-0.0.1-SNAPSHOT.jar
      
  # By default, copy to imos-artifact-test in test env, use 
  # input parameter to change this behavior
  copy-to-s3:
    name: Deploy S3
    needs: [build-upload]
    uses: aodn/common-workflow/.github/workflows/deploy-s3.yaml@main
    with:
      artifact: ${{needs.build-upload.outputs.artifact_name}}
      # Github repo environment, configuration needed
      environment: 'Dev'
    secrets:
      # Github repo level secrets, configuration needed
      role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}


```
----
## Versioning
1. The version format is major.minor.x
2. x wil increase on evey PR merged to main/master and new tag created on main/master
3. You can add message in PR to increase the major or minor version 
   * +semver: major to increase the major version by 1
   * +semver: minor to increase the minor version by 1
4. For branch build, it will be always the tag major.minor.(x+1).YOUR_BRANCH_NAME.meta-number


