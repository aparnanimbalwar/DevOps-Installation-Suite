#CronJon Kibana
#Runs every day at 00:30
30 0 * * * /root/kibana-logs-script/daily-log-script/konnect_kibana_ogs_daily-kibana.sh >> /var/log/kibana-daily-cron.log 2>&1

#Runs every Sunday at 01:00
0 1 * * 0 /root/kibana-logs-script/weekly-log-script/konnect_kibana_logs_weekly.sh >> /var/log/kibana-weekly-cron.log 2>&1

#Runs 1st day of every month at 02:00
0 2 1 * * /root/kibana-logs-script/monthly-log-script/konnect_kibana_logs_monthly.sh >> /var/log/kibana-monthly-cron.log 2>&1

