import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';

export interface SpeechListener {
  onStateChanged(isListening: boolean, message: string): void;
  onResult(text: string, isFinal: boolean): void;
  onError(message: string): void;
}

class SpeechService {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private listener: SpeechListener | null = null;
  private sessionId: string = '';
  private pendingAudio: Uint8Array = new Uint8Array(0);
  private listening: boolean = false;

  setListener(listener: SpeechListener | null): void {
    this.listener = listener;
  }

  isListening(): boolean {
    return this.listening;
  }

  async start(): Promise<boolean> {
    if (this.listening) {
      return true;
    }
    await this.release();
    try {
      this.sessionId = `starly_${Date.now()}`;
      this.engine = await speechRecognizer.createEngine({
        language: 'zh-CN',
        online: 1
      });
      const recognitionListener: speechRecognizer.RecognitionListener = {
        onStart: (_sessionId: string, _eventMessage: string): void => {
          this.listener?.onStateChanged(true, '正在聆听');
        },
        onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string): void => {
        },
        onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
          if (result.result.length > 0) {
            this.listener?.onResult(result.result, result.isFinal || result.isLast);
          }
        },
        onComplete: (_sessionId: string, _eventMessage: string): void => {
          this.listening = false;
          this.listener?.onStateChanged(false, '识别完成');
          this.shutdownEngine();
        },
        onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
          this.listening = false;
          this.listener?.onError(`语音识别失败（${errorCode}）：${errorMessage}`);
          this.shutdownEngine();
        }
      };
      this.engine.setListener(recognitionListener);

      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      this.capturer = await audio.createAudioCapturer(options);
      this.pendingAudio = new Uint8Array(0);
      this.capturer.on('readData', (buffer: ArrayBuffer) => {
        this.writeAudio(buffer);
      });
      this.engine.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16
        }
      });
      await this.capturer.start();
      this.listening = true;
      this.listener?.onStateChanged(true, '正在聆听');
      return true;
    } catch (error) {
      this.listener?.onError(`无法启动语音识别：${JSON.stringify(error)}`);
      await this.release();
      return false;
    }
  }

  async stop(): Promise<void> {
    if (!this.listening) {
      return;
    }
    this.listening = false;
    const capturer = this.capturer;
    this.capturer = null;
    if (capturer !== null) {
      try {
        capturer.off('readData');
        await capturer.stop();
        await capturer.release();
      } catch (_error) {
      }
    }
    try {
      this.engine?.finish(this.sessionId);
      this.listener?.onStateChanged(false, '正在整理识别结果');
    } catch (error) {
      this.listener?.onError(`结束识别失败：${JSON.stringify(error)}`);
      this.shutdownEngine();
    }
  }

  async cancel(): Promise<void> {
    try {
      this.engine?.cancel(this.sessionId);
    } catch (_error) {
    }
    await this.release();
    this.listener?.onStateChanged(false, '已取消');
  }

  async release(): Promise<void> {
    this.listening = false;
    const capturer = this.capturer;
    this.capturer = null;
    if (capturer !== null) {
      try {
        capturer.off('readData');
        await capturer.stop();
        await capturer.release();
      } catch (_error) {
      }
    }
    this.shutdownEngine();
    this.pendingAudio = new Uint8Array(0);
  }

  private writeAudio(buffer: ArrayBuffer): void {
    if (!this.listening || this.engine === null) {
      return;
    }
    const incoming = new Uint8Array(buffer);
    const combined = new Uint8Array(this.pendingAudio.length + incoming.length);
    combined.set(this.pendingAudio, 0);
    combined.set(incoming, this.pendingAudio.length);
    let offset = 0;
    while (combined.length - offset >= 1280) {
      try {
        this.engine.writeAudio(this.sessionId, combined.slice(offset, offset + 1280));
      } catch (error) {
        this.listener?.onError(`音频传输失败：${JSON.stringify(error)}`);
        return;
      }
      offset += 1280;
    }
    this.pendingAudio = combined.slice(offset);
  }

  private shutdownEngine(): void {
    if (this.engine !== null) {
      try {
        this.engine.shutdown();
      } catch (_error) {
      }
      this.engine = null;
    }
  }
}

export default new SpeechService();
