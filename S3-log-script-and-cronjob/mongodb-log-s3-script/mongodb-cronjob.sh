#MongoDB Logs-Uploading CronJob

0 1 * * * /home/ubuntu/log_Scripts/mongodb-log-script/daily-log-script/konnect_mongodb_logs_daily-mongodb.sh
0 2 * * 0 /home/ubuntu/log_Scripts/mongodb-log-script/weekly-log-script/konnect_mongodb_logs_weekly-mongodb.sh
0 3 1 * * /home/ubuntu/log_Scripts/mongodb-log-script/monthly-log-script/konnect_mongodb_logs_monthly-mongodb.sh

