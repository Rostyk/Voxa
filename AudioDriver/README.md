# Voxa Virtual Microphone (HAL driver)

`VoxaMic.driver` appears as **Voxa Virtual Microphone** in macOS and call apps.

**Voxa.app** captures your physical microphone and writes PCM into a shared-memory ring buffer; the driver reads that buffer for apps that select this input (Chrome Meet, QuickTime, etc.).

## Build

Requires [libASPL](https://github.com/gavv/libASPL) checked out at `../../libASPL` (sibling of the `Voxa` folder).

```bash
cd AudioDriver
chmod +x build.sh install.sh
./build.sh
```

## Install

```bash
sudo ./install.sh
```

Removes `SinewaveDevice.driver` if present, installs `VoxaMic.driver`, restarts Core Audio.

## Usage

1. Launch **Voxa.app** and allow **Microphone** when prompted (feeder starts only after that).
2. **System Settings → Sound → Input** → keep **MacBook Microphone** (or your headset), **not** Voxa Virtual Microphone.
3. Keep **Voxa.app running** in the background while you record or call.
4. In **Google Meet / Chrome / QuickTime** → microphone → **Voxa Virtual Microphone**.

Ring buffer and driver use **48 kHz stereo** (matches built-in mic hardware). After upgrading, reinstall: `./build.sh && sudo ./install.sh`.

If audio is garbled or silent: confirm `[VoxaMic] inFrames=512` (not thousands per tap), macOS default input is **not** Voxa, then reinstall the driver.

## Uninstall

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VoxaMic.driver
sudo killall coreaudiod
```
