Run every 2 minutes for testing purpose


*/2 * * * * /root/kibana-logs-script/daily-log-script/konnect_kibana_ogs_daily-kibana.sh >> /var/log/kibana-daily-cron.log 2>&1

*/2 * * * * /root/kibana-logs-script/weekly-log-script/konnect_kibana_logs_weekly.sh >> /var/log/kibana-weekly-cron.log 2>&1

*/2 * * * * /root/kibana-logs-script/monthly-log-script/konnect_kibana_logs_monthly.sh >> /var/log/kibana-monthly-cron.log 2>&1


