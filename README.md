# nr-fabric-action

This repository contains GitHub Actions intended for use to deploy Microsoft Fabric items within NRM Data Analytics Platform. Contents of the repository:
* Docker container to automate interaction with Fabric API
* Custom GHA to trigger Fabric deployments from GitHub

## Environment Variables
- `TENANT_ID` - _Required_ - Tenant ID is a globally unique identifier (GUID) that represents the organization’s Microsoft tenant
- `WORKSPACE_ID` - _Required_ - Workspace ID is a unique identifier for a specific Fabric workspace within your tenant

## GHA Usage Example
```sh
name: fabric-workflow

on: [push]

jobs:
  pull:
    name: Promote Fabric Items
    runs-on: ubuntu-22.04
    steps:
      - name: NR Fabric Action
        id: nr-fabric-action
        uses: bcgov/nr-fabric-action@main
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          WORKSPACE_ID: ${{ secrets.WORKSPACE_ID }}
```

##  Use of GHCR
The container image is built and pushed to the GHCR any time there is a push or PR to the **main** branch. Images are named according to the file path and tagged with the branch name.
```sh
docker pull ghcr.io/bcgov/nr-fabric-action:main
```