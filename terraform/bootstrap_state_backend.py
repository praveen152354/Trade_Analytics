"""
One-time bootstrap: creates the S3 bucket + DynamoDB table that Terraform's
own state backend (see backend.tf) needs. This can't be created BY
Terraform, since Terraform needs it to already exist before it can even
initialize with a remote backend (the classic chicken-and-egg). Run once
per AWS account; not part of the regular `terraform apply` flow, and
never run from CI.

    cd terraform
    python bootstrap_state_backend.py
"""
import os
import boto3
from dotenv import load_dotenv

load_dotenv(dotenv_path="../.env")

session = boto3.Session(
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name=os.environ["AWS_REGION"],
)

# Must match backend.tf exactly (backend blocks can't reference variables).
BUCKET = "trade-analytics-tfstate-ae7837e9"
TABLE = "trade-analytics-tf-lock"

s3 = session.client("s3")
try:
    s3.create_bucket(
        Bucket=BUCKET,
        CreateBucketConfiguration={"LocationConstraint": os.environ["AWS_REGION"]},
    )
    print(f"Created bucket {BUCKET}")
except s3.exceptions.BucketAlreadyOwnedByYou:
    print(f"Bucket {BUCKET} already exists (owned by us)")

s3.put_bucket_versioning(Bucket=BUCKET, VersioningConfiguration={"Status": "Enabled"})
s3.put_bucket_encryption(
    Bucket=BUCKET,
    ServerSideEncryptionConfiguration={"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]},
)
s3.put_public_access_block(
    Bucket=BUCKET,
    PublicAccessBlockConfiguration={
        "BlockPublicAcls": True, "IgnorePublicAcls": True,
        "BlockPublicPolicy": True, "RestrictPublicBuckets": True,
    },
)
print("Bucket versioning/encryption/public-access-block configured.")

dynamodb = session.client("dynamodb")
try:
    dynamodb.create_table(
        TableName=TABLE,
        KeySchema=[{"AttributeName": "LockID", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "LockID", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    print(f"Created DynamoDB table {TABLE}")
except dynamodb.exceptions.ResourceInUseException:
    print(f"Table {TABLE} already exists")

print("Done. Bucket:", BUCKET, "| Table:", TABLE)
