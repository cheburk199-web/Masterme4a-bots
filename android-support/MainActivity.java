package com.example.masterme4a_bot_control;

import android.os.Handler;
import android.os.Looper;

import java.net.InetSocketAddress;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.Arrays;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import org.geysermc.mcprotocollib.protocol.codec.MinecraftCodecHelper;
import org.geysermc.mcprotocollib.protocol.data.game.chunk.ChunkSection;

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
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.ClientboundSystemChatPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.entity.player.ClientboundPlayerPositionPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.level.ClientboundLevelChunkWithLightPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.level.ClientboundForgetLevelChunkPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.level.ClientboundBlockUpdatePacket;
import org.geysermc.mcprotocollib.protocol.data.game.entity.player.PositionElement;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.inventory.ClientboundOpenScreenPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.inventory.ClientboundContainerSetContentPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.clientbound.inventory.ClientboundContainerSetSlotPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.ServerboundChatCommandPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.player.ServerboundMovePlayerPosRotPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.level.ServerboundPlayerInputPacket;
import org.geysermc.mcprotocollib.protocol.packet.ingame.serverbound.inventory.ServerboundContainerClickPacket;
import org.geysermc.mcprotocollib.protocol.data.game.inventory.ContainerActionType;
import org.geysermc.mcprotocollib.protocol.data.game.inventory.ClickItemAction;
import org.geysermc.mcprotocollib.protocol.data.game.inventory.DropItemAction;
import org.geysermc.mcprotocollib.protocol.data.game.item.ItemStack;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "masterme4a/bot_control";
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private static final Map<Integer, ClientSession> sessions = new ConcurrentHashMap<>();
    private static final Map<Integer, BotRoute> routes = new ConcurrentHashMap<>();
    private MethodChannel channel;

    private static final class BotRoute {
        int stage = 0;
        int openContainerId = -1;
        int lastClickedContainerId = -1;
        volatile boolean joined = false;
        final Set<Long> loadedChunks = ConcurrentHashMap.newKeySet();
        volatile long chunkDataBytes = 0;
        volatile long blockUpdates = 0;
        volatile int lastChunkX = 0;
        volatile int lastChunkZ = 0;
        volatile double playerX = 0, playerY = 0, playerZ = 0;
        volatile float playerYaw = 0, playerPitch = 0;
        volatile boolean hasPosition = false;
        volatile MinecraftCodecHelper codecHelper;
        volatile int inventoryStateId = 0;
        volatile ItemStack[] inventoryItems = new ItemStack[46];
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        channel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this::handleMethodCall);
    }

    private void handleMethodCall(MethodCall call, MethodChannel.Result result) {
        if ("connectBot".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                Object nicknameValue = call.argument("nickname");
                String nickname = nicknameValue == null ? "" : nicknameValue.toString().trim();
                Object hostValue = call.argument("host");
                String host = hostValue == null ? "" : hostValue.toString().trim();
                int port = ((Number) call.argument("port")).intValue();
                connectBot(botId, nickname, host, port);
                result.success(true);
            } catch (Exception e) {
                result.error("CONNECT_ARGUMENTS", e.getMessage(), null);
            }
        } else if ("sendCommand".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                Object commandValue = call.argument("command");
                String command = commandValue == null ? "" : commandValue.toString();
                sendCommand(botId, command);
                result.success(true);
            } catch (Exception e) {
                result.error("SEND_COMMAND", e.getMessage(), null);
            }
        } else if ("moveBot".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                double forward = call.argument("forward") == null ? 0.0 : ((Number) call.argument("forward")).doubleValue();
                double strafe = call.argument("strafe") == null ? 0.0 : ((Number) call.argument("strafe")).doubleValue();
                boolean jump = Boolean.TRUE.equals(call.argument("jump"));
                boolean shift = Boolean.TRUE.equals(call.argument("shift"));
                boolean sprint = Boolean.TRUE.equals(call.argument("sprint"));
                moveBot(botId, forward, strafe, jump, shift, sprint);
                result.success(true);
            } catch (Exception e) {
                result.error("MOVE_BOT", e.getMessage(), null);
            }
        } else if ("lookBot".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                float yaw = ((Number) call.argument("yaw")).floatValue();
                float pitch = ((Number) call.argument("pitch")).floatValue();
                lookBot(botId, yaw, pitch);
                result.success(true);
            } catch (Exception e) {
                result.error("LOOK_BOT", e.getMessage(), null);
            }
        } else if ("inventoryClick".equals(call.method)) {
            try {
                int botId = ((Number) call.argument("botId")).intValue();
                int slot = ((Number) call.argument("slot")).intValue();
                String action = String.valueOf(call.argument("action"));
                sendInventoryClick(botId, slot, action);
                result.success(true);
            } catch (Exception e) {
                result.error("INVENTORY_CLICK", e.getMessage(), null);
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

    private void startKeepAliveService() {
        android.content.Intent intent = new android.content.Intent(this, BotKeepAliveService.class);
        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent);
        else startService(intent);
    }

    private void stopKeepAliveIfIdle() {
        if (routes.isEmpty() && sessions.isEmpty()) stopService(new android.content.Intent(this, BotKeepAliveService.class));
    }

    private void sendInventoryClick(int botId, int slot, String action) {
        ClientSession session = sessions.get(botId);
        BotRoute route = routes.get(botId);
        if (session == null || route == null || !route.joined) throw new IllegalStateException("Бот не подключён");
        if (slot < 0 || slot >= 46) throw new IllegalArgumentException("Неверный слот");
        ItemStack item = route.inventoryItems[slot];
        if (item == null) throw new IllegalStateException("Слот пуст");
        ContainerActionType mode;
        org.geysermc.mcprotocollib.protocol.data.game.inventory.ContainerAction click;
        if ("left".equals(action)) {
            mode = ContainerActionType.CLICK_ITEM;
            click = ClickItemAction.LEFT_CLICK;
        } else if ("right".equals(action)) {
            mode = ContainerActionType.CLICK_ITEM;
            click = ClickItemAction.RIGHT_CLICK;
        } else if ("drop".equals(action)) {
            mode = ContainerActionType.DROP_ITEM;
            click = DropItemAction.DROP_FROM_SELECTED;
        } else if ("dropStack".equals(action)) {
            mode = ContainerActionType.DROP_ITEM;
            click = DropItemAction.DROP_SELECTED_STACK;
        } else {
            throw new IllegalArgumentException("Неизвестное действие");
        }
        session.send(new ServerboundContainerClickPacket(
                0, route.inventoryStateId, slot, mode, click, null, Collections.emptyMap()
        ));
    }

    private void connectBot(int botId, String nickname, String host, int port) {
        if (botId < 0 || botId > 4) throw new IllegalArgumentException("Неверный номер профиля");
        if (nickname.isEmpty() || nickname.length() > 16) throw new IllegalArgumentException("Ник должен содержать 1–16 символов");
        if (host.isEmpty() || port < 1 || port > 65535) throw new IllegalArgumentException("Проверь адрес и порт");
        if (sessions.containsKey(botId) || routes.containsKey(botId)) {
            emit(botId, "Подключение уже выполняется или существует", "connecting");
            return;
        }

        startKeepAliveService();
        BotRoute route = new BotRoute();
        routes.put(botId, route);
        emit(botId, "Запуск фонового подключения…", "connecting");

        // Keep all network/protocol initialization off Android's main UI thread.
        Thread connector = new Thread(() -> {
            ClientSession session = null;
            try {
                if (routes.get(botId) != route) return;
                emit(botId, "Инициализирую протокол Minecraft 1.21.4…", "connecting");
                MinecraftProtocol protocol = new MinecraftProtocol(nickname);
                route.codecHelper = protocol.createHelper();

                emit(botId, "Создаю сетевую сессию…", "connecting");
                session = ClientNetworkSessionFactory.factory()
                        .setRemoteSocketAddress(new InetSocketAddress(host, port))
                        .setProtocol(protocol)
                        .create();
                if (routes.get(botId) != route) {
                    session.disconnect(Component.text("Подключение отменено"));
                    return;
                }
                sessions.put(botId, session);
                final ClientSession activeSession = session;

                activeSession.addListener(new SessionAdapter() {
                    @Override
                    public void packetReceived(Session current, Packet packet) {
                        if (packet instanceof ClientboundLoginPacket && !route.joined) {
                            route.joined = true;
                            emit(botId, "Вошёл в игровой мир. Отправляю /lite…", "joined");
                            current.send(new ServerboundChatCommandPacket("lite"));
                            emitWorld(botId, route);
                        } else if (packet instanceof ClientboundPlayerPositionPacket position) {
                            var p = position.getPosition();
                            var relative = position.getRelatives();
                            route.playerX = relative.contains(PositionElement.X) ? route.playerX + p.getX() : p.getX();
                            route.playerY = relative.contains(PositionElement.Y) ? route.playerY + p.getY() : p.getY();
                            route.playerZ = relative.contains(PositionElement.Z) ? route.playerZ + p.getZ() : p.getZ();
                            route.playerYaw = relative.contains(PositionElement.Y_ROT) ? route.playerYaw + position.getYRot() : position.getYRot();
                            route.playerPitch = relative.contains(PositionElement.X_ROT) ? route.playerPitch + position.getXRot() : position.getXRot();
                            route.hasPosition = true;
                            emitWorld(botId, route);
                        } else if (packet instanceof ClientboundLevelChunkWithLightPacket chunk) {
                            route.loadedChunks.add((((long) chunk.getX()) << 32) ^ (chunk.getZ() & 0xffffffffL));
                            route.chunkDataBytes += chunk.getChunkData().length;
                            route.lastChunkX = chunk.getX();
                            route.lastChunkZ = chunk.getZ();
                            decodeAndEmitChunk(botId, route, chunk);
                            emitWorld(botId, route);
                        } else if (packet instanceof ClientboundForgetLevelChunkPacket forget) {
                            route.loadedChunks.remove((((long) forget.getX()) << 32) ^ (forget.getZ() & 0xffffffffL));
                            emitWorld(botId, route);
                        } else if (packet instanceof ClientboundBlockUpdatePacket) {
                            route.blockUpdates++;
                            emitWorld(botId, route);
                        } else if (packet instanceof ClientboundSystemChatPacket chat) {
                            emitEvent(botId, "Чат сервера: " + chat.getContent().toString(), "chat");
                        } else if (packet instanceof ClientboundOpenScreenPacket open) {
                            route.openContainerId = open.getContainerId();
                            emit(botId, "Открылось меню. Жду содержимое…", "menu");
                        } else if (packet instanceof ClientboundContainerSetContentPacket content) {
                            // Player inventory is container 0. Emit server-authoritative slots for the UI.
                            if (content.getContainerId() == 0 && content.getItems() != null) {
                                route.inventoryStateId = content.getStateId();
                                route.inventoryItems = Arrays.copyOf(content.getItems(), Math.max(46, content.getItems().length));
                                emitInventory(botId, content.getItems());
                            }
                            if (route.openContainerId != content.getContainerId() || route.lastClickedContainerId == content.getContainerId() || route.stage >= 2) return;
                            int visibleSlotNumber = route.stage == 0 ? 3 : 25;
                            int protocolSlotIndex = visibleSlotNumber - 1;
                            if (content.getItems() == null || protocolSlotIndex >= content.getItems().length) {
                                emit(botId, "В меню нет слота №" + visibleSlotNumber + ". Остановил авто-выбор.", "error");
                                route.stage = 2;
                                return;
                            }
                            ItemStack clickedItem = content.getItems()[protocolSlotIndex];
                            if (clickedItem == null) {
                                emit(botId, "Слот №" + visibleSlotNumber + " пуст. Авто-выбор остановлен.", "error");
                                route.stage = 2;
                                return;
                            }
                            Map<Integer, ItemStack> changedSlots = new HashMap<>();
                            changedSlots.put(protocolSlotIndex, null);
                            current.send(new ServerboundContainerClickPacket(
                                    content.getContainerId(), content.getStateId(), protocolSlotIndex,
                                    ContainerActionType.CLICK_ITEM, ClickItemAction.LEFT_CLICK,
                                    clickedItem, changedSlots
                            ));
                            route.lastClickedContainerId = content.getContainerId();
                            route.stage++;
                            if (route.stage == 1) {
                                emit(botId, "Нажал 3-й слот. Жду второе меню…", "menu");
                            } else {
                                emit(botId, "Нажал 25-й слот. Маршрут выбора отправлен.", "route-sent");
                            }
                        } else if (packet instanceof ClientboundContainerSetSlotPacket slotUpdate) {
                            if (slotUpdate.getContainerId() == 0) {
                                route.inventoryStateId = slotUpdate.getStateId();
                                int changedSlot = slotUpdate.getSlot();
                                if (changedSlot >= 0 && changedSlot < route.inventoryItems.length) route.inventoryItems[changedSlot] = slotUpdate.getItem();
                                emitInventorySlot(botId, changedSlot, slotUpdate.getItem());
                            }
                        }
                    }

                    @Override
                    public void disconnected(DisconnectedEvent event) {
                        sessions.remove(botId, activeSession);
                        routes.remove(botId, route);
                        stopKeepAliveIfIdle();
                        String reason = event.getReason() == null ? "Соединение закрыто" : event.getReason().toString();
                        emit(botId, "Сервер отключил бота: " + reason, "disconnected");
                    }
                });

                emit(botId, "Соединяюсь с " + host + ":" + port + "…", "connecting");
                activeSession.connect(false);
                if (!route.joined && routes.get(botId) == route) {
                    emit(botId, "Сокет подключён. Ожидаю пакет входа от сервера…", "connecting");
                }
            } catch (Exception e) {
                if (session != null) sessions.remove(botId, session);
                routes.remove(botId, route);
                stopKeepAliveIfIdle();
                String detail = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                emit(botId, "Ошибка подключения: " + detail, "error");
            }
        }, "masterme4a-connect-" + botId);
        connector.setDaemon(true);
        connector.start();

        // Watch setup as well as login, so a blocked initialization is reported too.
        Thread watchdog = new Thread(() -> {
            try {
                TimeUnit.SECONDS.sleep(30);
                if (routes.get(botId) == route && !route.joined) {
                    routes.remove(botId, route);
                    ClientSession pending = sessions.remove(botId);
                    stopKeepAliveIfIdle();
                    if (pending != null) {
                        try { pending.disconnect(Component.text("Таймаут ожидания входа")); }
                        catch (Exception ignored) { }
                    }
                    emit(botId, "Таймаут 30 секунд: соединение не завершило инициализацию/вход. Проверь адрес, порт и тип авторизации (offline-mode).", "error");
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }, "masterme4a-watchdog-" + botId);
        watchdog.setDaemon(true);
        watchdog.start();
    }

    private void emitInventory(int botId, ItemStack[] items) {
        java.util.ArrayList<java.util.Map<String, Object>> slots = new java.util.ArrayList<>();
        for (int slot = 0; slot < items.length; slot++) {
            slots.add(itemPayload(slot, items[slot]));
        }
        emitInventoryPayload(botId, slots);
    }

    private void emitInventorySlot(int botId, int slot, ItemStack item) {
        if (slot < 0 || slot > 45) return;
        java.util.ArrayList<java.util.Map<String, Object>> slots = new java.util.ArrayList<>();
        // Send the slot update as a compact patch; Dart merges it into the last snapshot.
        slots.add(itemPayload(slot, item));
        mainHandler.post(() -> {
            if (channel == null) return;
            java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
            payload.put("botId", botId);
            payload.put("patch", true);
            payload.put("slots", slots);
            channel.invokeMethod("botInventory", payload);
        });
    }

    private java.util.Map<String, Object> itemPayload(int slot, ItemStack item) {
        java.util.HashMap<String, Object> value = new java.util.HashMap<>();
        value.put("slot", slot);
        value.put("id", item == null ? -1 : item.getId());
        value.put("count", item == null ? 0 : item.getAmount());
        return value;
    }

    private void emitInventoryPayload(int botId, java.util.ArrayList<java.util.Map<String, Object>> slots) {
        mainHandler.post(() -> {
            if (channel == null) return;
            java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
            payload.put("botId", botId);
            payload.put("patch", false);
            payload.put("slots", slots);
            channel.invokeMethod("botInventory", payload);
        });
    }

    // Decode the received chunk section palettes into a compact top-down block map.
    // Block state IDs are real server data; texture names/atlas are a later renderer step.
    private void decodeAndEmitChunk(int botId, BotRoute route, ClientboundLevelChunkWithLightPacket packet) {
        if (route.codecHelper == null) return;
        ByteBuf data = Unpooled.wrappedBuffer(packet.getChunkData());
        int[] topStates = new int[256];
        int[] topHeights = new int[256];
        Arrays.fill(topHeights, Integer.MIN_VALUE);
        int sectionIndex = 0;
        try {
            while (data.isReadable() && sectionIndex < 32) {
                ChunkSection section = route.codecHelper.readChunkSection(data);
                int sectionBaseY = (sectionIndex - 4) * 16; // vanilla Overworld section range starts at -4
                for (int localY = 0; localY < 16; localY++) {
                    for (int localZ = 0; localZ < 16; localZ++) {
                        for (int localX = 0; localX < 16; localX++) {
                            int state = section.getBlock(localX, localY, localZ);
                            int index = localZ * 16 + localX;
                            if (state != 0 && sectionBaseY + localY > topHeights[index]) {
                                topStates[index] = state;
                                topHeights[index] = sectionBaseY + localY;
                            }
                        }
                    }
                }
                sectionIndex++;
            }
            emitChunk(botId, packet.getX(), packet.getZ(), topStates, topHeights);
        } catch (Exception e) {
            emitEvent(botId, "Не удалось разобрать чанк: " + e.getMessage(), "chunk-decode");
        } finally {
            data.release();
        }
    }

    private void emitChunk(int botId, int chunkX, int chunkZ, int[] states, int[] heights) {
        mainHandler.post(() -> {
            if (channel == null) return;
            java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
            payload.put("botId", botId);
            payload.put("chunkX", chunkX);
            payload.put("chunkZ", chunkZ);
            java.util.ArrayList<Integer> stateList = new java.util.ArrayList<>(256);
            java.util.ArrayList<Integer> heightList = new java.util.ArrayList<>(256);
            for (int i = 0; i < 256; i++) {
                stateList.add(states[i]);
                heightList.add(heights[i] == Integer.MIN_VALUE ? -65 : heights[i]);
            }
            payload.put("states", stateList);
            payload.put("heights", heightList);
            channel.invokeMethod("botChunk", payload);
        });
    }

    private BotRoute requireMovableRoute(int botId) {
        ClientSession session = sessions.get(botId);
        BotRoute route = routes.get(botId);
        if (session == null || route == null || !route.joined || !route.hasPosition) {
            throw new IllegalStateException("Сначала подключи бота и дождись позиции в мире");
        }
        return route;
    }

    // Remote movement prototype: small client position steps; server remains authoritative.
    private void moveBot(int botId, double forward, double strafe, boolean jump, boolean shift, boolean sprint) {
        ClientSession session = sessions.get(botId);
        BotRoute route = requireMovableRoute(botId);
        forward = Math.max(-1.0, Math.min(1.0, forward));
        strafe = Math.max(-1.0, Math.min(1.0, strafe));
        double yawRad = Math.toRadians(route.playerYaw);
        double speed = sprint ? 0.42 : (shift ? 0.08 : 0.22);
        double dx = (-Math.sin(yawRad) * forward + Math.cos(yawRad) * strafe) * speed;
        double dz = (-Math.cos(yawRad) * forward - Math.sin(yawRad) * strafe) * speed;
        double dy = jump ? 0.42 : 0.0;
        route.playerX += dx;
        route.playerY += dy;
        route.playerZ += dz;
        session.send(new ServerboundPlayerInputPacket(forward > 0, forward < 0, strafe < 0, strafe > 0, jump, shift, sprint));
        session.send(new ServerboundMovePlayerPosRotPacket(true, false,
                route.playerX, route.playerY, route.playerZ, route.playerYaw, route.playerPitch));
        emitWorld(botId, route);
    }

    private void lookBot(int botId, float yaw, float pitch) {
        ClientSession session = sessions.get(botId);
        BotRoute route = requireMovableRoute(botId);
        route.playerYaw = yaw;
        route.playerPitch = Math.max(-90.0f, Math.min(90.0f, pitch));
        session.send(new ServerboundMovePlayerPosRotPacket(true, false,
                route.playerX, route.playerY, route.playerZ, route.playerYaw, route.playerPitch));
        emitWorld(botId, route);
    }

    private void sendCommand(int botId, String rawCommand) {
        ClientSession session = sessions.get(botId);
        BotRoute route = routes.get(botId);
        if (session == null || route == null || !route.joined) {
            throw new IllegalStateException("Сначала подключи бота и дождись входа в мир");
        }
        String command = rawCommand == null ? "" : rawCommand.trim();
        if (command.startsWith("/")) command = command.substring(1);
        if (command.isEmpty()) throw new IllegalArgumentException("Введи команду");
        if (command.length() > 256 || command.contains("\n") || command.contains("\r")) {
            throw new IllegalArgumentException("Команда слишком длинная или содержит перенос строки");
        }
        session.send(new ServerboundChatCommandPacket(command));
        emitEvent(botId, "Команда отправлена: /" + command, "command");
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
        stopKeepAliveIfIdle();
    }

    private void emit(int botId, String message, String status) {
        mainHandler.post(() -> {
            if (channel != null) {
                java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
                payload.put("botId", botId);
                payload.put("message", message);
                payload.put("status", status);
                channel.invokeMethod("botStatus", payload);
                channel.invokeMethod("botEvent", payload);
            }
        });
    }

    private void emitWorld(int botId, BotRoute route) {
        mainHandler.post(() -> {
            if (channel == null) return;
            java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
            payload.put("botId", botId);
            payload.put("joined", route.joined);
            payload.put("hasPosition", route.hasPosition);
            payload.put("x", route.playerX);
            payload.put("y", route.playerY);
            payload.put("z", route.playerZ);
            payload.put("yaw", route.playerYaw);
            payload.put("pitch", route.playerPitch);
            payload.put("loadedChunks", route.loadedChunks.size());
            payload.put("chunkDataBytes", route.chunkDataBytes);
            payload.put("blockUpdates", route.blockUpdates);
            payload.put("lastChunkX", route.lastChunkX);
            payload.put("lastChunkZ", route.lastChunkZ);
            channel.invokeMethod("botWorld", payload);
        });
    }

    private void emitEvent(int botId, String message, String status) {
        mainHandler.post(() -> {
            if (channel != null) {
                java.util.HashMap<String, Object> payload = new java.util.HashMap<>();
                payload.put("botId", botId);
                payload.put("message", message);
                payload.put("status", status);
                channel.invokeMethod("botEvent", payload);
            }
        });
    }

    @Override
    protected void onDestroy() {
        // Activity lifecycle must not disconnect sessions; the foreground service keeps the process alive.
        super.onDestroy();
    }
}
