0 1 * * * /root/elasticsearch-logs-script/daily-log-script/konnect_es_logs_daily.sh >> /var/log/es_daily_upload.log 2>&1
0 2 * * 0 /root/elasticsearch-logs-script/weekly-log-script/konnect_es_logs_weekly.sh >> /var/log/es_weekly_upload.log 2>&1
0 3 1 * * /root/elasticsearch-logs-script/monthly-log-script/konnect_es_logs_monthly.sh >> /var/log/es_monthly_upload.log 2>&1
