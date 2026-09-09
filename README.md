# AWS Multi-Account IaC Drift Detection Engine

An automated, cross-account Infrastructure as Code (OpenTofu/Terraform) drift detection engine orchestrated via Jenkins declarative pipelines and AWS IAM STS role assumption.

## Architecture Overview

                    +----------------------------+
                    |  Jenkins Orchestrator      |
                    |  (EC2 Fleet / ECS Agents)  |
                    +--------------+-------------+
                                   |
               +-------------------+-------------------+
               | STS:AssumeRole    | STS:AssumeRole    | STS:AssumeRole
               v                   v                   v
       +---------------+   +---------------+   +---------------+
       | Staging AWS   |   | Prod AWS      |   | Dev AWS       |
       | Account       |   | Account       |   | Account       |
       | (111111111111)|   | (222222222222)|   | (333333333333)|
       +---------------+   +---------------+   +---------------+

## ✨ Core Key Features

* **Parallel Multi-Account Scans:** Leverages Jenkins parallel execution threads across dynamically scaled worker nodes.
* **Non-Destructive Plan Inspections:** Executes `tofu plan -detailed-exitcode` with state locks disabled (`-lock=false`) to ensure non-blocking continuous inspection.
* **Cross-Account Security:** Operates under minimal privilege access using AWS STS AssumeRole credentials attached to EC2 Instance Metadata.
* **Automated Aggregation & Slack Alerting:** Parses, filters, and formats plan outputs into aggregated matrix summaries sent directly to Slack.

## 🚀 Detailed Exit Code Handling

The engine relies on IaC CLI binary exit codes to determine infrastructure status:
* **`0`**: No drift detected (Infrastructure state equals code definition).
* **`1`**: Execution error (IAM restriction, provider mismatch, network failure).
* **`2`**: Drift detected (Out-of-band manual changes found).

## 🛠 Prerequisites

1. Target AWS Accounts must deploy the `jenkins-drift-scanner` IAM Role configured to trust the central Jenkins Worker AWS account.
2. Jenkins Agent Nodes require `tofu` or `terraform` installed alongside AWS CLI v2.
