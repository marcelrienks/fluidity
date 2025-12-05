#!/usr/bin/env python3
import boto3
import json
import requests
import sys
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
from botocore.credentials import Credentials

# Check for command line argument
if len(sys.argv) != 2:
    print("Usage: python3 test_wake_lambda.py <wake_lambda_url>")
    print("Example: python3 test_wake_lambda.py https://your-function-url.lambda-url.region.on.aws/")
    sys.exit(1)

# Lambda Function URL from command line argument
WAKE_URL = sys.argv[1]

# Get credentials from fluidity profile
session = boto3.Session(profile_name='fluidity')
credentials = session.get_credentials()

# Create a signed request
def sign_request(url, method='POST', body='', service='lambda'):
    # Create AWS request
    aws_request = AWSRequest(
        method=method,
        url=url,
        headers={'Content-Type': 'application/json'},
        data=body
    )

    # Sign the request
    auth = SigV4Auth(credentials, service, session.region_name)
    auth.add_auth(aws_request)

    return aws_request

# Test the wake function
print("Testing Wake Lambda Function URL...")
print(f"URL: {WAKE_URL}")

# Create signed request
signed_request = sign_request(WAKE_URL, method='POST', body='{}')

# Make the request
headers = dict(signed_request.headers)
headers['Content-Type'] = 'application/json'

print("Making signed request...")
response = requests.post(WAKE_URL, headers=headers, data='{}')

print(f"Status Code: {response.status_code}")
print(f"Response: {response.text}")

if response.status_code == 200:
    print("✅ Wake function call successful!")
else:
    print("❌ Wake function call failed")