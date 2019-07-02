data "aws_caller_identity" "current" {}

resource "aws_dynamodb_table" "access_tokens" {
  name         = "${var.prefix}-s3-credentials-access-tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "accessToken"

  attribute {
    name = "accessToken"
    type = "S"
  }
}

data "aws_iam_policy_document" "assume_lambda_role" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "s3_credentials_lambda" {
  name                 = "${var.prefix}-S3CredentialsLambda"
  assume_role_policy   = data.aws_iam_policy_document.assume_lambda_role.json
  permissions_boundary = var.permissions_boundary
}

data "aws_iam_policy_document" "s3_credentials_lambda" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [var.sts_credentials_lambda_arn]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "s3_credentials_lambda" {
  policy = data.aws_iam_policy_document.s3_credentials_lambda.json
  role   = aws_iam_role.s3_credentials_lambda.id
}

resource "aws_lambda_function" "s3_credentials" {
  function_name = "${var.prefix}-s3-credentials-endpoint"
  # TODO Fetch this from ... somewhere. Or package it with the module zip file? Probably the better option
  filename         = "${path.module}/dist/src.zip"
  source_code_hash = filebase64sha256("${path.module}/dist/src.zip")
  handler          = "index.handler"
  role             = aws_iam_role.s3_credentials_lambda.arn
  runtime          = "nodejs8.10"
  timeout          = 10
  memory_size      = 320
  environment {
    variables = {
      DISTRIBUTION_REDIRECT_ENDPOINT = "https://${var.rest_api.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}/${var.redirect_path}"
      # TODO Remove this stub value
      # public_buckets            = ""
      EARTHDATA_BASE_URL        = var.urs_url
      EARTHDATA_CLIENT_ID       = var.urs_client_id
      EARTHDATA_CLIENT_PASSWORD = var.urs_client_password
      AccessTokensTable         = aws_dynamodb_table.access_tokens.id
      STSCredentialsLambda      = var.sts_credentials_lambda_arn
    }
  }
}

resource "aws_lambda_permission" "lambda_permission" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_credentials.function_name
  principal     = "apigateway.amazonaws.com"

  # The /*/*/* part allows invocation from any stage, method and resource path
  # within API Gateway REST API.
  source_arn = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${var.rest_api.id}/*/*/*"
  # source_arn = aws_api_gateway_deployment.s3_credentials.execution_arn
}

# GET /s3credentials

resource "aws_api_gateway_resource" "s3_credentials" {
  rest_api_id = var.rest_api.id
  parent_id   = var.rest_api.root_resource_id
  path_part   = var.s3credentials_path
}

resource "aws_api_gateway_method" "s3_credentials" {
  rest_api_id   = var.rest_api.id
  resource_id   = aws_api_gateway_resource.s3_credentials.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "s3_credentials" {
  rest_api_id             = var.rest_api.id
  resource_id             = aws_api_gateway_resource.s3_credentials.id
  http_method             = aws_api_gateway_method.s3_credentials.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.s3_credentials.invoke_arn
}

# GET /redirect

resource "aws_api_gateway_resource" "s3_credentials_redirect" {
  rest_api_id = var.rest_api.id
  parent_id   = var.rest_api.root_resource_id
  path_part   = var.redirect_path
}

resource "aws_api_gateway_method" "s3_credentials_redirect" {
  rest_api_id   = var.rest_api.id
  resource_id   = aws_api_gateway_resource.s3_credentials_redirect.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "s3_credentials_redirect" {
  rest_api_id             = var.rest_api.id
  resource_id             = aws_api_gateway_resource.s3_credentials_redirect.id
  http_method             = aws_api_gateway_method.s3_credentials_redirect.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.s3_credentials.invoke_arn
}

# API deployment

resource "aws_api_gateway_deployment" "s3_credentials" {
  depends_on = [
    "aws_api_gateway_integration.s3_credentials_redirect",
    "aws_api_gateway_integration.s3_credentials"
  ]

  rest_api_id = var.rest_api.id
  stage_name  = var.stage_name
}
