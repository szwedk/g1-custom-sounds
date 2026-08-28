# Running Voice Studio on the robot

Voice Studio can run on your workstation or on the robot's development computer.
Running it on the robot avoids depending on an SSH session and keeps DDS traffic
local. Audio still reaches the chest speaker through the `AudioClient` API; see
[../../docs/audio-architecture.md](../../docs/audio-architecture.md).

## Install

```bash
mkdir -p ~/g1-voice-studio
# copy voice/app, voice/lib, voice/prompts.tsv and voice/deploy/run.sh across
sudo apt-get install -y ffmpeg

# a current SDK is required for AudioClient.PlayStream
git clone --depth 1 https://github.com/unitreerobotics/unitree_sdk2_python.git \
    ~/g1-voice-studio/vendor/unitree_sdk2_python

chmod +x ~/g1-voice-studio/run.sh
```

Set `G1_IFACE` in `run.sh` (or the environment) to the robot's DDS interface.

## Run as a service

```bash
mkdir -p ~/.config/systemd/user
cp ~/g1-voice-studio/voice/deploy/g1-voice-studio.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now g1-voice-studio
sudo loginctl enable-linger "$USER"     # start at boot without a login session
```

## Access

The server binds to localhost on the robot. Forward the port and open it locally:

```bash
ssh -N -L 8899:127.0.0.1:8766 <user>@<ROBOT_IP>
# http://127.0.0.1:8899
```
