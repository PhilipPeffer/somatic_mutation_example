{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListPipelineBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::__BUCKET__"
    },
    {
      "Sid": "ReadWritePipelineBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::__BUCKET__/*"
    }
  ]
}
