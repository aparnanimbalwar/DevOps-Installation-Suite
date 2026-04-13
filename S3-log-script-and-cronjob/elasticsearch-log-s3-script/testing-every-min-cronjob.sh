PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# TEST MODE – Every 2 minutes
*/2 * * * * /root/elasticsearch-logs-script/daily-log-script/konnect_es_logs_daily.sh >> /var/log/es_daily_upload.log 2>&1

# TEST MODE – Offset by 2 minutes
1-59/2 * * * * /root/elasticsearch-logs-script/weekly-log-script/konnect_es_logs_weekly.sh >> /var/log/es_weekly_upload.log 2>&1

# TEST MODE – Offset by another 2 minutes
*/2 * * * * sleep 120 && /root/elasticsearch-logs-script/monthly-log-script/konnect_es_logs_monthly.sh >> /var/log/es_monthly_upload.log 2>&1
