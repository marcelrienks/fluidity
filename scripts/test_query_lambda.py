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
    print("Usage: python3 test_query_lambda.py <query_lambda_url>")
    print("Example: python3 test_query_lambda.py https://your-function-url.lambda-url.region.on.aws/")
    sys.exit(1)

# Lambda Function URL from command line argument
QUERY_URL = sys.argv[1]

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

# Test the query function
print("Testing Query Lambda Function URL...")
print(f"URL: {QUERY_URL}")

# Create request body for query (needs instance_id)
query_body = json.dumps({
    "instance_id": "instance-id-placeholder"
})

# Create signed request
signed_request = sign_request(QUERY_URL, method='POST', body=query_body)

# Make the request
headers = dict(signed_request.headers)
headers['Content-Type'] = 'application/json'

print("Making signed request...")
print(f"Request body: {query_body}")
response = requests.post(QUERY_URL, headers=headers, data=query_body)

print(f"Status Code: {response.status_code}")
print(f"Response: {response.text}")

if response.status_code == 200:
    print("✅ Query function call successful!")
    # Parse and display the response
    try:
        response_json = response.json()
        status = response_json.get('status', 'unknown')
        public_ip = response_json.get('public_ip', 'none')
        message = response_json.get('message', 'no message')

        print(f"Status: {status}")
        print(f"Public IP: {public_ip}")
        print(f"Message: {message}")

        if status == 'ready' and public_ip:
            print("✅ Server is ready with IP:", public_ip)
        elif status == 'pending':
            print("⏳ Server is still starting up")
        else:
            print("❌ Server status:", status)
    except json.JSONDecodeError:
        print("❌ Failed to parse JSON response")
else:
    print("❌ Query function call failed")