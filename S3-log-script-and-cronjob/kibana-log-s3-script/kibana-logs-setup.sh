Configure Kibana to Write File Logs : 



vi /etc/kibana/kibana.yml

logging:
  appenders:
    file:
      type: file
      fileName: /var/log/kibana/kibana.log
      layout:
        type: pattern
  root:
    appenders: [file]
    level: info

==========================================================


🔧 Step 2: Create Directory & Permissions

mkdir -p /var/log/kibana
chown kibana:kibana /var/log/kibana
chmod 750 /var/log/kibana


==========================================================

🔄 Step 3: Restart Kibana

systemctl restart kibana
systemctl status kibana

==========================================================

Verify logs:
ls -lh /var/log/kibana
tail -f /var/log/kibana/kibana.log


==========================================================

🔁 Step 4: Enable Log Rotation (Mandatory)

vi /etc/logrotate.d/kibana

/var/log/kibana/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}


logrotate -f /etc/logrotate.d/kibana


==========================================================

Test once:

logrotate -f /etc/logrotate.d/kibana


will get : 

kibana.log
kibana.log.1.gz

==========================================================


