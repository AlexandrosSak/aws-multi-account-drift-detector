data "aws_caller_identity" "current" {}

# Policy enabling Jenkins worker node to assume cross-account execution roles
data "aws_iam_policy_document" "assume_role_drift_scanner" {
  version = "2012-10-17"

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-controller",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-worker-node"
      ]
    }
  }
}

# Read-only policy attached to target account execution roles
data "aws_iam_policy_document" "drift_scanner_permissions" {
  version = "2012-10-17"

  # Standard AWS resource inspection permissions
  statement {
    sid    = "AllowInfrastructureReadAccess"
    actions = [
      "ec2:Describe*",
      "s3:List*",
      "s3:Get*",
      "iam:Get*",
      "iam:List*",
      "rds:Describe*",
      "ecs:Describe*",
      "ecs:List*"
    ]
    resources = ["*"]
  }

  # Terraform Remote State Read Access
  statement {
    sid    = "AllowRemoteStateBucketAccess"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::company-tf-state-*",
      "arn:aws:s3:::company-tf-state-*/*"
    ]
  }
}

resource "aws_iam_role" "drift_scanner" {
  name               = "jenkins-drift-scanner"
  assume_role_policy = data.aws_iam_policy_document.assume_role_drift_scanner.json
}

resource "aws_iam_role_policy" "drift_scanner_attach" {
  name   = "jenkins-drift-scanner-policy"
  role   = aws_iam_role.drift_scanner.id
  policy = data.aws_iam_policy_document.drift_scanner_permissions.json
}
