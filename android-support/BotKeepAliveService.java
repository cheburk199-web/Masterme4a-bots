package com.example.masterme4a_bot_control;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

public class BotKeepAliveService extends Service {
    private static final String CHANNEL_ID = "masterme4a_bot_keepalive";
    private static final int NOTIFICATION_ID = 4104;
    private PowerManager.WakeLock wakeLock;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder = new Notification.Builder(this, CHANNEL_ID);
        else builder = new Notification.Builder(this);
        Notification notification = builder
                .setContentTitle("MASTERME4A Bots")
                .setContentText("Боты продолжают работать в фоне")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        PowerManager powerManager = (PowerManager) getSystemService(POWER_SERVICE);
        if (powerManager != null) {
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Masterme4aBots:NetworkKeepAlive");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, "Работа ботов в фоне", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Показывает, что Minecraft-боты остаются подключёнными");
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) manager.createNotificationChannel(channel);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
