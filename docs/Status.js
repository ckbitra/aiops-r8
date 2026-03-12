aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --details

  Chandra@CT026Chandra MINGW64 ~/OneDrive - Centennial Technologies Inc/Documents/DEMO/aiops-r8/terraform (master)
$ aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --details
{
    "CommandInvocations": [
        {
            "CommandId": "7f17e245-7aa6-4598-9b87-b9e928e722cf",
            "InstanceId": "i-02318aef4c892847d",
            "InstanceName": "ip-10-0-10-85.us-east-2.compute.internal",
            "Comment": "",
            "DocumentName": "AWS-RunShellScript",
            "DocumentVersion": "$DEFAULT",
            "RequestedDateTime": "2026-03-11T22:45:23.032000-04:00",
            "Status": "Success",
            "StatusDetails": "Success",
            "StandardOutputUrl": "",
            "StandardErrorUrl": "",
            "CommandPlugins": [
                {
                    "Name": "aws:runShellScript",
                    "Status": "Success",
                    "StatusDetails": "Success",
                    "ResponseCode": 0,
                    "ResponseStartDateTime": "2026-03-11T22:45:23.173000-04:00",
                    "ResponseFinishDateTime": "2026-03-11T22:47:59.954000-04:00",
                    "Output": "Updating Subscription Management repositories.\nUnable to read consumer identity\n\nThis system is not registered with an entitlement server. You can use subscription-manager to register.\n\nLast metadata expiration check: 3:09:58 ago on Wed 11 Mar 2026 11:35:27 PM UTC.\nDependencies resolved.\n================================================================================\n Package           Arch   Version                 Repository               Size\n================================================================================\nInstalling:\n kernel            x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  11 M\n kernel-core       x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  44 M\n kernel-modules    x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  36 M\nUpgrading:\n brotli            x86_64 1.0.6-4.el8_10          rhel-8-baseos-rhui-rpms 322 k\n kernel-tools      x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  11 M\n kernel-tools-libs x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  11 M\n libblkid          x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms 220 k\n libfdisk          x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms 253 k\n libmount          x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms 236 k\n libnfsidmap       x86_64 1:2.3.3-68.el8_10       rhel-8-baseos-rhui-rpms 122 k\n libsmartcols      x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms 179 k\n libuuid           x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms  99 k\n openssl           x86_64 1:1.1.1k-15.el8_6       rhel-8-baseos-rhui-rpms 710 k\n openssl-libs      x86_64 1:1.1.1k-15.el8_6       rhel-8-baseos-rhui-rpms 1.5 M\n platform-python   x86_64 3.6.8-73.el8_10         rhel-8-baseos-rhui-rpms  88 k\n python3-libs      x86_64 3.6.8-73.el8_10         rhel-8-baseos-rhui-rpms 7.9 M\n python3-perf      x86_64 4.18.0-553.111.1.el8_10 rhel-8-baseos-rhui-rpms  11 M\n util-linux        x86_64 2.32.1-48.el8_10        rhel-8-baseos-rhui-rpms 2.5 M\n\nTransaction Summary\n================================================================================\nInstall   3 Packages\nUpgrade  15 Packages\n\nTotal download size: 137 M\nDownloading Packages:\n(1/18): kernel-4.18.0-553.111.1.el8_10.x86_64.r  32 MB/s |  11 MB     00:00    \n(2/18): libblkid-2.32.1-48.el8_10.x86_64.rpm     13 MB/s | 220 kB     00:00    \n(3/18): libfdisk-2.32.1-48.el8_10.x86_64.rpm     22 MB/s | 253 kB     00:00    \n(4/18): libmount-2.32.1-48.el8_10.x86_64.rpm     \n---Output truncated---",
                    "StandardOutputUrl": "",
                    "StandardErrorUrl": "",
                    "OutputS3Region": "us-east-2",
                    "OutputS3BucketName": "",
                    "OutputS3KeyPrefix": ""
                }
            ],
            "ServiceRole": "",
            "NotificationConfig": {
                "NotificationArn": "",
                "NotificationEvents": [],
                "NotificationType": ""
            },
            "CloudWatchOutputConfig": {
                "CloudWatchLogGroupName": "",
                "CloudWatchOutputEnabled": false
            }
        }
    ]
}