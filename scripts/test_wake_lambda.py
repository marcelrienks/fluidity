#!/usr/bin/env python3
import boto3
import json
import requests
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
from botocore.credentials import Credentials

# Lambda Function URL
WAKE_URL = "https://ldayerz6h2ovcc3yl7o3agl7wu0fhmfo.lambda-url.eu-west-1.on.aws/"

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