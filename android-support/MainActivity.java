package com.example.masterme4a_bot_control;

import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;

import java.net.InetSocketAddress;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import net.kyori.adventure.text.Component;
import org.geysermc.mcprotocollib.network.ClientSession;
import org.geysermc.mcprotocollib.network.Session;
import org.geysermc.mcprotocollib.network.event.session.DisconnectedEvent;
import org.geysermc.mcprotocollib.network.event.session.SessionAdapter;
import org.geysermc.mcprotocollib.network.factory.ClientNetworkSessionFactory;
import org.geysermc.mcprotocollib.network.packet.Packet;
import org.geysermc.mcprotocollib.protocol.MinecraftProtocol;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.ClientboundLoginPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.inventory.ClientboundOpenScreenPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.inventory.ClientboundContainerSetContentPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.ServerboundChatCommandPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.inventory.ServerboundContainerClickPacket;
import org.geysermc.mcprotocollib.protocol.data.game.inventory.ContainerActionType;
import org.geysermc.mcprotocollib.protocol.data.game.inventory.ClickItemAction;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "masterme4a/bot_control";
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<Integer, ClientSession> sessions = new ConcurrentHashMap<>();
    private final Map<Integer, BotRoute> routes = new ConcurrentHashMap<>();
    private MethodChannel channel;

    private static final class BotRoute {
        int stage = 0;
        int openContainerId = -1;
        boolean joined = false;
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        channel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this::handleMethodCall);
    }

    private void handleMethodCall(MethodCall call, MethodChannel.Result result) {
        if ("connectBot".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                String nickname = String.valueOf(call.argument("nickname")).trim();
                String host = String.valueOf(call.argument("host")).trim();
                int port = ((Number) call.argument("port")).intValue();
                connectBot(botId, nickname, host, port);
                result.success(true);
            } catch (Exception e) {
                result.error("CONNECT_ARGUMENTS", e.getMessage(), null);
            }
        } else if ("disconnectBot".equals(call.method)) {
            int botId = ((Number) call.argument("botId")).intValue();
            disconnectBot(botId);
            result.success(true);
        } else if ("disconnectAll".equals(call.method)) {
            for (Integer id : sessions.keySet()) disconnectBot(id);
            result.success(true);
        } else {
            result.notImplemented();
        }
    }

    private void connectBot(int botId, String nickname, String host, int port) {
        if (botId < 0 || botId > 4) throw new IllegalArgumentException("Неверный номер профиля");
        if (nickname.isEmpty() || nickname.length() > 16) throw new IllegalArgumentException("Ник должен содержать 1–16 символов");
        if (host.isEmpty() || port < 1 || port > 65535) throw new IllegalArgumentException("Проверь адрес и порт");
        if (sessions.containsKey(botId)) {
            emit(botId, "Подключение уже существует", "connecting");
            return;
        }

        emit(botId, "Создаём игровое соединение 1.21.4…", "connecting");
        BotRoute route = new BotRoute();
        routes.put(botId, route);

        // Nickname-only login is supported only by servers explicitly configured for offline mode.
        // This does not bypass online-mode authentication.
        MinecraftProtocol protocol = new MinecraftProtocol(nickname);
        ClientSession session = ClientNetworkSessionFactory.factory()
                .setRemoteSocketAddress(new InetSocketAddress(host, port))
                .setProtocol(protocol)
                .create();
        sessions.put(botId, session);

        session.addListener(new SessionAdapter() {
            @Override
            public void packetReceived(Session current, Packet packet) {
                if (packet instanceof ClientboundLoginPacket && !route.joined) {
                    route.joined = true;
                    emit(botId, "Вошёл в игровой мир. Отправляю /lite…", "joined");
                    current.send(new ServerboundChatCommandPacket("lite"));
                } else if (packet instanceof ClientboundOpenScreenPacket open) {
                    route.openContainerId = open.getContainerId();
                    emit(botId, "Открылось меню. Жду содержимое…", "menu");
                } else if (packet instanceof ClientboundContainerSetContentPacket content) {
                    if (route.openContainerId != content.getContainerId() || route.stage >= 2) return;
                    int visibleSlotNumber = route.stage == 0 ? 3 : 25;
                    int protocolSlotIndex = visibleSlotNumber - 1;
                    if (content.getItems() == null || protocolSlotIndex >= content.getItems().length) {
                        emit(botId, "В меню нет слота №" + visibleSlotNumber + ". Остановил авто-выбор.", "error");
                        route.stage = 2;
                        return;
                    }
                    current.send(new ServerboundContainerClickPacket(
                            content.getContainerId(),
                            content.getStateId(),
                            protocolSlotIndex,
                            ContainerActionType.CLICK_ITEM,
                            ClickItemAction.LEFT_CLICK,
                            null,
                            Collections.emptyMap()
                    ));
                    route.stage++;
                    if (route.stage == 1) {
                        emit(botId, "Нажал 3-й слот. Жду второе меню…", "menu");
                    } else {
                        emit(botId, "Нажал 25-й слот. Маршрут выбора отправлен.", "route-sent");
                    }
                }
            }

            @Override
            public void disconnected(DisconnectedEvent event) {
                sessions.remove(botId);
                routes.remove(botId);
                String reason = event.getReason() == null ? "Соединение закрыто" : event.getReason().toString();
                emit(botId, reason, "disconnected");
            }
        });

        try {
            session.connect();
        } catch (Exception e) {
            sessions.remove(botId);
            routes.remove(botId);
            emit(botId, "Ошибка подключения: " + e.getMessage(), "error");
        }
    }

    private void disconnectBot(int botId) {
        ClientSession session = sessions.remove(botId);
        routes.remove(botId);
        if (session != null) {
            try {
                session.disconnect(Component.text("Отключено пользователем"));
            } catch (Exception ignored) { }
        }
        emit(botId, "Отключён", "disconnected");
    }

    private void emit(int botId, String message, String status) {
        mainHandler.post(() -> {
            if (channel != null) {
                java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
                payload.put("botId", botId);
                payload.put("message", message);
                payload.put("status", status);
                channel.invokeMethod("botStatus", payload);
            }
        });
    }

    @Override
    protected void onDestroy() {
        for (Integer id : sessions.keySet()) disconnectBot(id);
        super.onDestroy();
    }
}
