import 'dart:async';
import 'dart:io';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:dart_openai/dart_openai.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_session.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:path_provider/path_provider.dart';

// also include file picker on app start
// also for web and then include links to appstore playstore and neostore

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme lightColorScheme;
        ColorScheme darkColorScheme;

        if (lightDynamic != null && darkDynamic != null) {
          // On Android S+ devices, use the provided dynamic color scheme.
          // (Recommended) Harmonize the dynamic color scheme' built-in semantic colors.
          lightColorScheme = lightDynamic.harmonized();
          // (Optional) Customize the scheme as desired. For example, one might
          // want to use a brand color to override the dynamic [ColorScheme.secondary].
          // lightColorScheme = lightColorScheme.copyWith(secondary: _brandBlue);
          // (Optional) If applicable, harmonize custom colors.
          // lightCustomColors = lightCustomColors.harmonized(lightColorScheme);

          // Repeat for the dark color scheme.
          darkColorScheme = darkDynamic.harmonized();
          // darkColorScheme = darkColorScheme.copyWith(secondary: _brandBlue);
          // darkCustomColors = darkCustomColors.harmonized(darkColorScheme);
        } else {
          // Otherwise, use fallback schemes.
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: Colors.teal,
          );
          darkColorScheme = ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          );
        }

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: lightColorScheme,
            // extensions: [lightCustomColors],
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: darkColorScheme,
            // extensions: [darkCustomColors],
          ),
          themeMode: ThemeMode.system,
          //TODO localisations
          home: const MyHomePage(),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late StreamSubscription _intentDataStreamSubscription;

  AndroidOptions _getAndroidOptions() => const AndroidOptions(
        encryptedSharedPreferences: true,
      );
  late final storage;

  bool initialized = false;
  String? openAIKey;
  String? model;

  String? filePath;
  String? transcription;
  String? shortened;
  String? summary;

  int page = 0;
  int selectedText = 0;

  PlayerWaveStyle waveStyle = PlayerWaveStyle(scaleFactor: 120);
  PlayerController playerController = PlayerController();
  late StreamSubscription<PlayerState> playerStateSubscription;
  late StreamSubscription<int> playerDurationSubscription;
  Duration playerTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    // For sharing images coming from outside the app while the app is in the memory
    _intentDataStreamSubscription = FlutterSharingIntent.instance.getMediaStream().listen((List<SharedFile> value) {
      newFile(value.firstOrNull?.value);
      if (kDebugMode) {
        print("Shared: getMediaStream ${value.map((f) => f.value).join(",")}");
      }
    }, onError: (err) {
      if (kDebugMode) {
        print("getIntentDataStream error: $err");
      }
    });

    // For sharing images coming from outside the app while the app is closed
    FlutterSharingIntent.instance.getInitialSharing().then((List<SharedFile> value) {
      if (kDebugMode) {
        print("Shared: getInitialMedia ${value.map((f) => f.value).join(",")}");
      }
      newFile(value.firstOrNull?.value);
    });

    storage = FlutterSecureStorage(aOptions: _getAndroidOptions());

    playerStateSubscription = playerController.onPlayerStateChanged.listen((playerState) async {
      setState(() {});
      playerTime = Duration(milliseconds: await playerController.getDuration(playerState.isPlaying ? DurationType.current : DurationType.max));
    });
    playerDurationSubscription = playerController.onCurrentDurationChanged.listen((ms) async {
      setState(() {
        playerTime = Duration(milliseconds: ms);
      });
    });

    asyncInit();
  }

  dispose() {
    super.dispose();
    _intentDataStreamSubscription.cancel();
    playerStateSubscription.cancel();
    playerDurationSubscription.cancel();
  }

  void asyncInit() async {
    openAIKey = await storage.read(key: "openAIKey");
    await initializeOpenAI();
    setState(() {
      initialized = true;
    });
  }

  Future<void> initializeOpenAI() async {
    if (openAIKey != null) {
      OpenAI.apiKey = openAIKey!;
      List<OpenAIModelModel> models = await getModels();
      String? model = await storage.read(key: "textModel");
      if (model == null) {
        model = models.firstWhere((element) => element.id.startsWith("gpt")).id;
        storage.write(key: "textModel", value: model);
      }
    }
  }

  Future<List<OpenAIModelModel>> getModels() async => await OpenAI.instance.model.list();

  void reset() async {
    setState(() {
      filePath = null;
      transcription = null;
      shortened = null;
      summary = null;
      selectedText = 0;
    });
  }

  Future<void> newFile(String? path) async {
    if (path == null) return;
    playerController.preparePlayer(
      path: path,
      shouldExtractWaveform: true,
      noOfSamples: waveStyle.getSamplesForWidth(MediaQuery.of(context).size.width * 0.5),
    );
    setState(() {
      reset();
      filePath = path;
    });
    // playerController.extractWaveformData(
    //   path: path,
    //   noOfSamples: waveStyle.getSamplesForWidth(MediaQuery.of(context).size.width * 0.5),
    // );
  }

  void transcribe() async {
    if (filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("No File selected."),
      ));
      return;
    }
    setState(() {
      transcription = "";
    });
    final Directory tempDir = await getTemporaryDirectory();
    String outputPath = tempDir.path + "/converted.mp3";
    String inputPath = filePath!;

    // if(Platform.isAndroid) {
    //   String? newInputPath = await FFmpegKitConfig.selectDocumentForRead(inputPath);
    //   String? newOutputPath = await FFmpegKitConfig.selectDocumentForWrite(outputPath, "audio/mp3");
    //   print("newInputPath: $newInputPath");
    //   print("newOutputPath: $newOutputPath");
    //
    //   if(newInputPath == null || newOutputPath == null) {
    //     print("File could not be converted, because Paths are null.");
    //     return;
    //   }
    //
    //   String? newSafInputPath = await FFmpegKitConfig.getSafParameterForRead(newInputPath);
    //   String? newSafOutputPath = await FFmpegKitConfig.getSafParameterForWrite(newOutputPath);
    //   print("newSafInputPath: $newSafInputPath");
    //   print("newSafOutputPath: $newSafOutputPath");
    //
    //   if(newSafInputPath == null || newSafOutputPath == null) {
    //     print("File could not be converted, because SAF Paths are null.");
    //     return;
    //   }
    //
    //   inputPath = newSafInputPath;
    //   outputPath = newSafOutputPath;
    // }
    File inputFile = File(inputPath);
    File outputFile = File(outputPath);
    if (!inputFile.existsSync()) {
      print("File could not be converted, because it does not exist.");
      setState(() {
        transcription = null;
      });
      return;
    }
    if (outputFile.existsSync()) {
      outputFile.deleteSync();
    }
    // await FFmpegKitConfig.enableLogs();
    // FFmpegKitConfig.enableLogCallback((log) {
    //   if (kDebugMode) {
    //     print("FFmpegKit: ${log.getMessage()}");
    //   }
    // });
    FFmpegSession session = await FFmpegKit.execute('-i ${inputFile.path} ${outputFile.path}');
    if (!((await session.getReturnCode())?.isValueSuccess() ?? false)) {
      print("File could not be converted.");
      setState(() {
        transcription = null;
      });
      if (mounted) {
        Fluttertoast.showToast(
          msg: "File could not be converted.",
          toastLength: Toast.LENGTH_SHORT,
        );
      }
      return;
    }
    OpenAIAudioModel transcriptionResponse = await OpenAI.instance.audio.createTranscription(
      file: outputFile,
      model: "whisper-1",
      responseFormat: OpenAIAudioResponseFormat.text,
    );
    outputFile.delete();
    setState(() {
      transcription = transcriptionResponse.text;
    });
  }

  void shorten() async {
    if (transcription == null) {
      setState(() {
        shortened = null;
      });
      return;
    }

    setState(() {
      shortened = "";
    });

    final chatStream = OpenAI.instance.chat.createStream(
      model: model ?? "gpt-3.5-turbo",
      messages: [
        OpenAIChatCompletionChoiceMessageModel(
          content: [
            OpenAIChatCompletionChoiceMessageContentItemModel.text("""Shorten the following transcription of a voice message in the same language.
                 Do not summarize it but clear up the text and make it more readable.
                 Remove fill words and clear up sentence structures while keeping the style the same.
                 Keep the language the same."""),
          ],
          role: OpenAIChatMessageRole.system,
        ),
        OpenAIChatCompletionChoiceMessageModel(
          content: [
            OpenAIChatCompletionChoiceMessageContentItemModel.text(
              transcription!,
            ),
          ],
          role: OpenAIChatMessageRole.user,
        ),
      ],
    );

    chatStream.listen(
      (streamChatCompletion) {
        final content = streamChatCompletion.choices.first.delta.content;
        setState(() {
          shortened = shortened! + (content?.first.text ?? "");
        });
      },
      onDone: () {
        if (kDebugMode) {
          print("Done Shortening");
        }
      },
    );
    setState(() {});
  }

  void summarize() async {
    if (transcription == null) {
      setState(() {
        summary = null;
      });
      return;
    }
    setState(() {
      summary = "";
    });
    final chatStream = OpenAI.instance.chat.createStream(
      model: model ?? "gpt-3.5-turbo",
      messages: [
        OpenAIChatCompletionChoiceMessageModel(
          content: [
            OpenAIChatCompletionChoiceMessageContentItemModel.text("""Sumamrize the following transcription of a voice message in the same language.
                Keep the most important information and shorten the text as much as possible.
                Keep the language the same."""),
          ],
          role: OpenAIChatMessageRole.system,
        ),
        OpenAIChatCompletionChoiceMessageModel(
          content: [
            OpenAIChatCompletionChoiceMessageContentItemModel.text(
              transcription!,
            ),
          ],
          role: OpenAIChatMessageRole.user,
        ),
      ],
    );

    chatStream.listen(
      (streamChatCompletion) {
        final content = streamChatCompletion.choices.first.delta.content;
        setState(() {
          summary = summary! + (content?.first.text ?? "");
        });
      },
      onDone: () {
        if (kDebugMode) {
          print("Done Summarizing");
        }
      },
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const Center(child: CupertinoActivityIndicator());
    String? selectedTextString = [transcription, shortened, summary][selectedText];
    return Scaffold(
      body: IndexedStack(
        index: page,
        children: [
          openAIKey == null
              ? const Center(child: Text("Please enter your OpenAI API key in the settings"))
              : SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      filePath != null
                          ? Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: IntrinsicWidth(
                                child: Card(
                                  color: Theme.of(context).colorScheme.tertiaryContainer,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            onPressed: () async {
                                              playerController.playerState.isPlaying
                                                  ? await playerController.pausePlayer()
                                                  : await playerController.startPlayer(
                                                      finishMode: FinishMode.pause,
                                                    );
                                              setState(() {});
                                            },
                                            icon: Icon(
                                              playerController.playerState.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                            ),
                                          ),
                                          AudioFileWaveforms(
                                            playerController: playerController,
                                            waveformType: WaveformType.fitWidth,
                                            animationDuration: const Duration(milliseconds: 100),
                                            playerWaveStyle: waveStyle,
                                            enableSeekGesture: true,
                                            size: Size(MediaQuery.of(context).size.width * 0.7, MediaQuery.of(context).size.height * 0.05),
                                          ),
                                        ],
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              filePath!.split("/").last,
                                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                            ),
                                            Text(
                                              "${playerTime.inHours > 0 ? "${playerTime.inHours}:" : ""}${playerTime.inMinutes.remainder(60).toString().padLeft(2, "0")}:${playerTime.inSeconds.remainder(60).toString().padLeft(2, "0")}",
                                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                            ),
                                          ],
                                        ),
                                      )
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : SizedBox(
                              height: MediaQuery.of(context).size.height * 0.10,
                              child: const Center(
                                child: Text("No File selected. Share a voice message to get started."),
                              ),
                            ),
                      SegmentedButton(
                        multiSelectionEnabled: false,
                        segments: const <ButtonSegment<int>>[
                          ButtonSegment(
                            value: 0,
                            icon: Icon(Icons.transcribe),
                            label: Text("Transcript"),
                          ),
                          ButtonSegment(
                            value: 1,
                            icon: Icon(Icons.short_text),
                            label: Text("Shortened"),
                          ),
                          ButtonSegment(
                            value: 2,
                            icon: Icon(Icons.summarize),
                            label: Text("Summary"),
                          ),
                        ],
                        selected: <int>{selectedText},
                        onSelectionChanged: (Set<int> newSelection) {
                          setState(() {
                            selectedText = newSelection.first;
                          });
                          if (selectedText >= 1 && [transcription, shortened, summary][selectedText] == null) [transcribe, shorten, summarize][selectedText]();
                        },
                      ),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width, minHeight: MediaQuery.of(context).size.height * 0.2),
                          child: Card(
                            color: Color.alphaBlend(
                              Theme.of(context).colorScheme.surfaceTint.withOpacity(0.05),
                              Theme.of(context).colorScheme.surface,
                            ),
                            surfaceTintColor: Colors.transparent,
                            child: selectedTextString == null
                                ? [
                                    Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          FilledButton(
                                            onPressed: transcribe,
                                            child: const Text("Transcribe"),
                                          ),
                                          const Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 32.0),
                                            child: Text(
                                              "Only transcribe files if you have the right to do so.\nThe file will be uploaded to OpenAI.",
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Center(child: Text("Generate a transcription first.")),
                                    const Center(child: Text("Generate a transcription first.")),
                                  ][selectedText]
                                : selectedTextString!.isEmpty
                                    ? const Center(child: CupertinoActivityIndicator())
                                    : Stack(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(16.0),
                                          child: SingleChildScrollView(
                                              child: Padding(
                                                  padding: const EdgeInsets.only(bottom: 16.0),
                                                  child: SelectableText(
                                                    selectedTextString!,
                                                    style: Theme.of(context).textTheme.bodyLarge,
                                                  )),
                                            ),
                                        ),
                                        Align(
                                          alignment: Alignment.bottomRight,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(8.0),
                                              color: Color.alphaBlend(
                                                Theme.of(context).colorScheme.surfaceTint.withOpacity(0.05),
                                                Theme.of(context).colorScheme.surface,
                                              ),
                                            ),
                                            padding: const EdgeInsets.all(4.0),
                                            child: Text(
                                              "${selectedTextString!.split(RegExp("[\\.\\ \\!\\n\\?\\,]+")).length} words | ${selectedTextString.length} characters",
                                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                            ),
                                          ),
                                        )
                                      ],
                                    ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          Scaffold(
            appBar: AppBar(
              title: const Text("Settings"),
            ),
            body: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.vpn_key),
                  title: const Text("OpenAI API Key"),
                  onTap: () async {
                    showDialog(
                      context: context,
                      builder: (context) {
                        TextEditingController controller = TextEditingController();
                        return AlertDialog(
                          icon: const Icon(Icons.vpn_key),
                          title: const Text("OpenAI API Key"),
                          content: TextField(
                            controller: controller,
                            decoration: const InputDecoration(
                              labelText: "OpenAI API Key",
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                Navigator.pop(context);
                              },
                              child: const Text("Cancel"),
                            ),
                            TextButton(
                              onPressed: () async {
                                String key = controller.text;
                                if (key.isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                    content: Text("Please enter a key."),
                                  ));
                                  return;
                                }
                                openAIKey = key;
                                storage.write(key: "openAIKey", value: key);
                                initializeOpenAI();
                                //TODO test key
                                setState(() {});
                                if (mounted) Navigator.pop(context);
                              },
                              child: const Text("Save Key"),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text("Text Model"),
                  onTap: () async {
                    List<OpenAIModelModel> models = await getModels();
                    if (mounted) {
                      showDialog(
                        context: context,
                        builder: (context) {
                          return AlertDialog(
                            icon: const Icon(Icons.text_fields),
                            title: const Text("Text Model"),
                            content: DropdownButton<String>(
                              value: model,
                              onChanged: (String? newValue) {
                                setState(() {
                                  model = newValue;
                                });
                                storage.write(key: "textModel", value: newValue);
                              },
                              items: models.where((element) => element.id.startsWith("gpt")).map<DropdownMenuItem<String>>((OpenAIModelModel value) {
                                return DropdownMenuItem<String>(
                                  value: value.id,
                                  child: Text(value.id),
                                );
                              }).toList(),
                            ),
                          );
                        },
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: page,
        onTap: (index) {
          setState(() {
            page = index;
          });
        },
        showSelectedLabels: false,
        showUnselectedLabels: false,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: "Home",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_rounded),
            label: "Settings",
          ),
        ],
      ),
    );
  }
}
