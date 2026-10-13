import receiver from 'libharmonyscreen.so';
import display from '@ohos.display';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';

interface ConnectionStats {
  linkMbps: number;
  videoMbps: number;
  rttMs: number;
  testState: number;
  testMbps: number;
  testMB: number;
  width: number;
  height: number;
}

@Component
struct MetricRow {
  @Prop label: string = '';
  @Prop value: string = '';
  build() {
    Row({ space: 12 }) {
      Text(this.label).fontSize(15).fontColor('#c0c8d2').layoutWeight(1);
      Text(this.value).fontSize(16).fontColor('#ffffff');
    }.width('100%').padding({ top: 8, bottom: 8 });
  }
}

PersistentStorage.persistProp('harmonyShowFPS', false);
PersistentStorage.persistProp('harmonyShowConnectionStats', false);

@Entry
@Component
struct Index {
  private controller: XComponentController = new XComponentController();
  private timer: number = -1;
  @State private connectRequested: boolean = true;
  @StorageLink('harmonyForeground') @Watch('foregroundChanged') private foreground: boolean = true;
  private retryAt: number = 0;
  private appliedOrientation: number = -1;
  private orientationPending: boolean = false;

  private reportViewport(width: number, height: number): void {
    try {
      const screen = display.getDefaultDisplaySync();
      const w = Math.round(vp2px(width));
      const h = Math.round(vp2px(height));
      receiver.viewport(w, h, screen.xDPI, screen.yDPI);
      console.info(`HarmonyScreen viewport ${w}x${h}, DPI ${screen.xDPI}x${screen.yDPI}`);
    } catch { console.warn('HarmonyScreen could not read the panel size'); }
  }

  private updateOrientation(): void {
    const requested = receiver.orientation();
    if (requested < 0 || requested === this.appliedOrientation || this.orientationPending) { return; }
    this.orientationPending = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const mode = requested === 1 ? window.Orientation.PORTRAIT : requested === 2 ?
      window.Orientation.LANDSCAPE : window.Orientation.AUTO_ROTATION;
    window.getLastWindow(context).then((win: window.Window) => win.setPreferredOrientation(mode))
      .then(() => { this.appliedOrientation = requested; })
      .catch(() => { console.warn('HarmonyScreen orientation change was refused'); })
      .finally(() => { this.orientationPending = false; });
  }
  private hideControlsAt: number = 0;
  private statsLogAt: number = 0;
  private lastControlActionAt: number = 0;
  @State private message: string = 'Waiting for Mac';
  @State private nextStep: string = 'Connect this Huawei to your Mac with a data cable. Unlock it and approve USB debugging, then open Harmony Side Screen on the Mac.';
  @State private receivedFrames: number = 0;
  @State private displayFPS: number = 0;
  @StorageLink('harmonyShowFPS') private showFPS: boolean = false;
  @StorageLink('harmonyShowConnectionStats') private showConnectionStats: boolean = false;
  @State private settingsOpen: boolean = false;
  @State private linkMbps: number = -1;
  @State private videoMbps: number = 0;
  @State private rttMs: number = -1;
  @State private testState: number = 0;
  @State private testMbps: number = 0;
  @State private testMB: number = 0;
  @State private streamSize: string = '等待画面';
  @State private active: boolean = false;
  @State private ready: boolean = false;
  @State private controlsVisible: boolean = true;
  @State private port: string = '54322';
  @State private placement: number = -1;

  private foregroundChanged(): void {
    if (this.foreground) { this.retryAt = 0; return; }
    receiver.stop();
    this.active = false;
    this.receivedFrames = 0;
    this.displayFPS = 0;
    this.controlsVisible = true;
  }

  private placeScreen(side: number): void {
    const alignment = this.placement >= 0 ? this.placement % 3 : 1;
    if (!receiver.place(side, alignment)) {
      this.nextStep = 'Reconnect after updating Harmony Side Screen on your Mac to change screen position.';
    }
    this.hideControlsAt = 0;
  }

  private connect(): void {
    if (!this.ready || !this.foreground || this.active) { return; }
    const portNumber = Number(this.port);
    if (portNumber < 1024 || portNumber > 65535 || !Number.isInteger(portNumber)) {
      this.message = 'Enter a port between 1024 and 65535';
      this.connectRequested = false;
      return;
    }
    this.retryAt = Date.now() + 3000;
    this.receivedFrames = 0;
    this.displayFPS = 0;
    this.active = receiver.start(this.controller.getXComponentSurfaceId(), portNumber);
    // The connection worker may retry; the controls and instructions stay still.
    this.message = 'Waiting for Mac';
    this.hideControlsAt = Date.now() + 2500;
  }

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      if (this.foreground) { this.updateOrientation(); }
      if (this.active) {
        const frames = receiver.frames();
        if (this.receivedFrames === 0 && frames > 0) {
          console.info('HarmonyScreen: first video frame submitted');
        }
        this.receivedFrames = frames;
        this.displayFPS = receiver.fps();
        const stats = JSON.parse(receiver.diagnostics()) as ConnectionStats;
        this.linkMbps = stats.linkMbps;
        this.videoMbps = stats.videoMbps;
        this.rttMs = stats.rttMs;
        this.testState = stats.testState;
        this.testMbps = stats.testMbps;
        this.testMB = stats.testMB;
        this.streamSize = `${stats.width} × ${stats.height}`;
        this.placement = receiver.placement();
        if (frames > 0) { this.message = 'Connected over USB'; }
        if (frames > 0 && Date.now() >= this.statsLogAt) {
          console.info(`HarmonyScreen receiver: ${this.displayFPS.toFixed(1)} FPS; ${frames} decoded frames submitted`);
          this.statsLogAt = Date.now() + 5000;
        }
        if (!receiver.running()) {
          const reason = receiver.status();
          console.info(`HarmonyScreen reconnect: ${reason}`);
          this.active = false;
          this.receivedFrames = 0;
          this.displayFPS = 0;
          this.controlsVisible = true;
          this.message = 'Waiting for Mac';
          this.nextStep = reason.includes('picture') || reason.includes('decoder') || reason.includes('Decoder') ?
            'On your Mac, open Harmony Side Screen and check Screen Recording permission. If the picture is still missing, try a lower resolution.' :
            'Connect this Huawei to your Mac with a data cable. Unlock it and approve USB debugging, then open Harmony Side Screen on the Mac.';
          this.retryAt = Date.now() + 3000;
        } else if (frames > 0 && this.hideControlsAt > 0 && !this.settingsOpen && Date.now() >= this.hideControlsAt) {
          this.controlsVisible = false;
        }
      } else if (this.connectRequested && Date.now() >= this.retryAt) {
        this.connect();
      }
    }, 500);
  }

  onPageShow(): void { this.foreground = true; }
  onPageHide(): void {
    this.foreground = false;
    this.foregroundChanged();
  }
  aboutToDisappear(): void {
    clearInterval(this.timer);
    receiver.stop();
  }
  onBackPress(): boolean {
    if (this.settingsOpen) { this.settingsOpen = false; return true; }
    if (!this.controlsVisible) {
      this.controlsVisible = true;
      this.hideControlsAt = 0;
      return true;
    }
    return false;
  }

  private openYouWo(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData', uri: 'https://youwo.ai' })
      .catch(() => { this.message = 'Visit YouWo.ai in your browser'; });
  }

  private toggleControls(): void {
    if (Date.now() - this.lastControlActionAt < 350) { return; }
    this.lastControlActionAt = Date.now();
    console.info('HarmonyScreen controls: surface tap');
    if (!this.active || this.receivedFrames === 0) { return; }
    this.controlsVisible = !this.controlsVisible;
    this.settingsOpen = false;
    this.hideControlsAt = 0; // A deliberately opened panel stays until the user closes it.
  }

  private openSettingsPanel(): void {
    this.lastControlActionAt = Date.now();
    this.controlsVisible = true;
    this.settingsOpen = true;
    this.hideControlsAt = 0;
    console.info('HarmonyScreen controls: settings button');
  }

  private hideAllControls(): void {
    this.lastControlActionAt = Date.now();
    this.controlsVisible = false;
    this.settingsOpen = false;
    this.hideControlsAt = 0;
    console.info('HarmonyScreen controls: dismissed');
  }

  private runTransferTest(): void {
    this.hideControlsAt = 0;
    if (receiver.testConnection()) { this.testState = 1; this.testMB = 0; }
  }

  @Builder
  private connectionSettings() {
    Column({ space: 10 }) {
      Row() {
        Text('连接与画面').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#ffffff').layoutWeight(1);
        Button('收起设置').onClick(() => { this.settingsOpen = false; });
      }.width('100%');
      MetricRow({ label: '连接方式', value: 'HDC · USB 数据线' });
      MetricRow({ label: 'USB 协商速度', value: this.linkMbps > 0 ?
        (this.linkMbps >= 1000 ? `${(this.linkMbps / 1000).toFixed(1)} Gbps` : `${this.linkMbps} Mbps`) :
        (this.linkMbps === 0 ? '无法读取' : '请更新 Mac 端') });
      MetricRow({ label: '当前视频传输', value: `${this.videoMbps.toFixed(1)} Mbps` });
      MetricRow({ label: 'USB 往返时间', value: this.rttMs >= 0 ? `${this.rttMs.toFixed(1)} ms` : '测量中' });
      MetricRow({ label: '视频分辨率', value: this.streamSize });
      MetricRow({ label: '接收并解码', value: `${this.displayFPS.toFixed(1)} FPS` });
      Text('协商速度是接口上限；视频码率随内容变化。往返时间包含排队，不是画面总延迟。FPS 统计解码提交，实际屏幕刷新可能更低。')
        .fontSize(13).fontColor('#b7c0cc').width('100%');
      Divider().color('#424953');
      Row() {
        Text('实时显示 FPS').fontSize(16).fontColor('#ffffff').layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.showFPS }).id('fpsToggle')
          .onChange((value: boolean) => { this.showFPS = value; });
      }.width('100%');
      Row() {
        Text('实时显示连接信息').fontSize(16).fontColor('#ffffff').layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.showConnectionStats }).id('connectionStatsToggle')
          .onChange((value: boolean) => { this.showConnectionStats = value; });
      }.width('100%');
      Text('分别选择是否显示帧率、视频码率／往返时间／分辨率。选择会保留，收起后仍可轻点右上角「设置」。')
        .fontSize(13).fontColor('#b7c0cc').width('100%');
      Divider().color('#424953');
      Text('线材与连接测试').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#ffffff').width('100%');
      Text('传输并校验 16 MiB 测试数据，画面会短暂停顿。结果包含线材、端口和 HDC 的共同影响；换线后用同一端口重复测试。')
        .fontSize(13).fontColor('#b7c0cc').width('100%');
      if (this.testState === 1 || this.testState === 2) {
        Text(`测试中 · ${this.testMB.toFixed(1)} / 16 MiB`).id('transferProgress').fontColor('#b9f3df');
      } else if (this.testState === 3) {
        Text(`校验通过 · ${this.testMbps.toFixed(1)} Mbps · ${(this.testMbps / 8).toFixed(1)} MB/s`)
          .id('transferResult').fontSize(17).fontColor('#b9f3df');
        Text('这是本次 HDC 有效吞吐量，不是线材的极限速度。').fontSize(13).fontColor('#b7c0cc');
      } else if (this.testState === 4) {
        Text('测试未完成或校验失败。请检查连接后重试。').id('transferFailure').fontColor('#ffcf95');
      }
      Button(this.testState === 1 || this.testState === 2 ? '正在测试' : '测试 USB 传输').id('transferTest')
        .enabled(this.linkMbps >= 0 && this.testState !== 1 && this.testState !== 2)
        .onClick(() => { this.runTransferTest(); });
      if (this.placement >= 0) {
        Divider().color('#424953');
        Text('放在 Mac 的哪一侧').fontSize(16).fontColor('#ffffff').width('100%');
        Row({ space: 8 }) {
          ForEach(['左侧', '右侧', '上方', '下方'], (label: string, index: number) => {
            Button(label).layoutWeight(1)
              .backgroundColor(Math.floor(this.placement / 3) === index ? '#b9f3df' : '#30353e')
              .fontColor(Math.floor(this.placement / 3) === index ? '#111318' : '#eeeeee')
              .onClick(() => { this.placeScreen(index); });
          });
        }.width('100%');
      }
    }.alignItems(HorizontalAlign.Start).padding(20).width('100%');
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'display', type: XComponentType.SURFACE, controller: this.controller, libraryname: 'harmonyscreen' })
        .width('100%').height('100%').hitTestBehavior(HitTestMode.None).zIndex(0)
        .onAreaChange((_old: Area, area: Area) => { this.reportViewport(Number(area.width), Number(area.height)); })
        .onLoad(() => { this.ready = true; this.connect(); })
        .onDestroy(() => { receiver.stop(); this.ready = false; this.active = false; });

      if (!this.active || this.receivedFrames === 0) {
        Column() {}.width('100%').height('100%').backgroundColor('#000000')
          .hitTestBehavior(HitTestMode.None).zIndex(1);
      }
      // A concrete hit target above the native surface; it never forwards a tap to the Mac.
      Button('', { type: ButtonType.Normal }).id('screenTapTarget')
        .accessibilityText('显示或隐藏控制栏')
        .width('100%').height('100%').backgroundColor(Color.Transparent).borderRadius(0)
        .hitTestBehavior(this.controlsVisible ? HitTestMode.None : HitTestMode.Block).zIndex(2)
        .onClick(() => { this.toggleControls(); });

      if ((this.showFPS || this.showConnectionStats) && !this.controlsVisible && this.active && this.receivedFrames > 0) {
        Column({ space: 4 }) {
          if (this.showFPS) {
            Text(`${this.displayFPS.toFixed(1)} stream FPS`).fontSize(14).fontColor('#b9f3df');
          }
          if (this.showConnectionStats) {
            Text(`${this.videoMbps.toFixed(1)} Mbps · ${this.rttMs >= 0 ? `${this.rttMs.toFixed(1)} ms RTT` : '测量中'}`)
              .fontSize(13).fontColor('#ffffff');
            Text(this.streamSize).fontSize(13).fontColor('#c0c8d2');
          }
        }.id('liveDiagnostics').alignItems(HorizontalAlign.Start)
          .padding(10).backgroundColor('#D9111318').borderRadius(10)
          .position({ x: 16, y: 16 }).hitTestBehavior(HitTestMode.Default).zIndex(3)
          .onClick(() => { this.openSettingsPanel(); });
      }
      // Always-visible entry point: controls never depend only on a hidden gesture or FPS badge.
      if (!this.controlsVisible && this.active && this.receivedFrames > 0) {
        Button('设置').id('persistentSettings').fontSize(14).fontColor('#ffffff')
          .backgroundColor('#D9111318').borderRadius(18).padding(4)
          .position({ x: '86%', y: 16 }).zIndex(5)
          .onClick(() => { this.openSettingsPanel(); });
      }
      if (this.controlsVisible) {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('Harmony Side Screen').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#b9f3df');
              Text(this.receivedFrames > 0 ? 'USB 已连接 · YouWo.ai' : this.message).fontSize(14).fontColor('#eeeeee');
            }.alignItems(HorizontalAlign.Start).layoutWeight(1);
            if (this.receivedFrames > 0) {
              Button('设置').id('openSettings').onClick(() => {
                this.settingsOpen = !this.settingsOpen; this.hideControlsAt = 0;
              });
              Button('隐藏').id('hideControls').onClick(() => { this.hideAllControls(); });
            }
          }.padding(16).width('100%').backgroundColor('#ED111318').borderRadius(16);
          Button('', { type: ButtonType.Normal }).id('controlBackdrop')
            .width('100%').layoutWeight(1).backgroundColor(Color.Transparent).borderRadius(0)
            .accessibilityText('隐藏控制栏').onClick(() => { this.toggleControls(); });
          if (this.settingsOpen && this.receivedFrames > 0) {
            Scroll() { this.connectionSettings(); }
              .width('100%').height('72%').backgroundColor('#F5111318').borderRadius(16)
              .scrollBar(BarState.Auto).hitTestBehavior(HitTestMode.Default);
          }
          if (this.receivedFrames === 0) {
            Column({ space: 8 }) {
              Text(this.nextStep).fontSize(17).fontColor('#eeeeee');
              Text(this.connectRequested ? '设备就绪后会自动重新连接。' : '已暂停自动连接。')
                .fontSize(13).fontColor('#b9f3df');
            }.padding(20).width('100%').backgroundColor('#ED111318').borderRadius(16);
          }
          Row({ space: 12 }) {
            Text(this.receivedFrames > 0 ? '轻点画面显示／隐藏控制栏' : 'USB 自动连接')
              .fontSize(14).fontColor('#eeeeee').layoutWeight(1);
            if (this.connectRequested && this.receivedFrames === 0) {
              Button('重试').enabled(this.ready).onClick(() => {
                receiver.stop(); this.active = false; this.retryAt = 0; this.connect();
              });
            }
            Button(this.connectRequested ? (this.receivedFrames > 0 ? '断开' : '暂停连接') : '连接 USB').enabled(this.ready)
              .onClick(() => {
                this.settingsOpen = false;
                if (this.connectRequested) {
                  this.connectRequested = false; receiver.stop(); this.active = false;
                  this.receivedFrames = 0; this.displayFPS = 0; this.message = '已断开';
                } else { this.connectRequested = true; this.connect(); }
              });
          }.padding(16).width('100%').backgroundColor('#ED111318').borderRadius(16);
        }.padding(24).width('100%').height('100%').hitTestBehavior(HitTestMode.Default).zIndex(4);
      }
    }.width('100%').height('100%').backgroundColor('#000000')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }
}
