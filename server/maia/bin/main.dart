import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:maia_api/maia_api.dart';
import 'package:maia_api/src/jobs/job_mirror.dart';
import 'package:maia_jobs/maia_jobs.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  final config = Config.fromEnv();
  final db = Db.connect(config);
  final queries = await NamedQueries.load(config.queriesDir);

  final cloud = config.parasailApiKey == null
      ? null
      : ParasailEmbeddings(
          apiKey: config.parasailApiKey!,
          model: config.parasailEmbedModel,
          baseUrl: config.parasailBaseUrl,
        );
  final local = config.ollamaUrl == null
      ? null
      : Embeddings(
          baseUrl: Uri.parse(config.ollamaUrl!),
          model: config.embeddingModel,
        );

  PgBossQueue? jobs;
  Pool<void>? pool;
  if (config.pgUrl case final url?) {
    final u = Uri.parse(url);
    final opened = Pool<void>.withEndpoints([
      Endpoint(
        host: u.host,
        port: u.port == 0 ? 5432 : u.port,
        database: u.pathSegments.first,
        username: u.userInfo.split(':').first,
        password: u.userInfo.split(':').last,
      ),
    ], settings: const PoolSettings(sslMode: SslMode.disable));
    pool = opened;
    await opened.run((s) => const PgBossSchema().install(s));
    jobs = PgBossQueue(opened);
    await jobs.createQueue('embed');
    await jobs.createQueue(
      'derive-presence',
      const QueueOptions(policy: QueuePolicy.stately),
    );
    await jobs.createQueue(
      'conclude',
      const QueueOptions(policy: QueuePolicy.singleton),
    );
    await jobs.createQueue(
      'etl',
      const QueueOptions(policy: QueuePolicy.singleton),
    );
    await jobs.createQueue(
      'weave',
      const QueueOptions(policy: QueuePolicy.singleton),
    );
  }

  JobRunner? runner;
  if (jobs != null) {
    runner = JobRunner(
      jobs,
      log: (message, [error]) {
        stdout.writeln(error == null ? message : '$message $error');
      },
    );
    await runner.work(
      'embed',
      EmbedJob(db: db, local: local, cloud: cloud).run,
    );
    if (config.ollamaUrl != null) {
      await runner.work(
        'conclude',
        GraphConcluder(
          db: db,
          ollama: Uri.parse(config.ollamaUrl!),
          model: config.concludeModel,
        ).run,
      );
    }
    final root = config.hackathonRoot ?? _guessHackathonRoot();
    final python = config.pythonBin;
    if (Directory('$root/etl').existsSync()) {
      final fixture = File('$root/etl/fixtures/sample.json');
      final oneSecret = Platform.environment['ONE_SECRET'];
      final etl = PythonJob(
        python: python,
        module: 'etl.worker',
        workdir: root,
        environment: {
          'PYTHONPATH': root,
          'MAIA_API_URL': 'http://127.0.0.1:${config.port}',
          'CONNECT_URL': config.connectSidecarUrl,
          if ((oneSecret == null || oneSecret.isEmpty) && fixture.existsSync())
            'MAIA_ETL_FIXTURE': fixture.path,
        },
      );
      await runner.work('etl', (job) {
        return mirrorPythonJob(
          db,
          data: job.data,
          pgbossId: job.id,
          inner: () => etl.run(job),
        );
      });
    }
    if (Directory('$root/swarm').existsSync()) {
      final weave = PythonJob(
        python: python,
        module: 'swarm.weave',
        workdir: root,
      );
      await runner.work('weave', (job) {
        return mirrorPythonJob(
          db,
          data: job.data,
          pgbossId: job.id,
          inner: () => weave.run(job),
        );
      });
    }
    await runner.work(
      'dream',
      DreamJob(
        db: db,
        youApiKey: config.youApiKey,
        library: PersonLibrary(Directory('${config.dataDir}/library')),
      ).run,
      const QueueOptions(
        policy: QueuePolicy.singleton,
        expireIn: Duration(minutes: 30),
      ),
    );
    final boss = pool;
    if (boss != null) await reconcileJobMirrors(db, boss);
    await runner.start();
  }

  // Nightly research, and a sync pass so connected accounts keep cloning.
  DreamClock? dreams;
  SyncClock? sync;
  if (jobs != null) {
    dreams = DreamClock(jobs);
    dreams.start();
  }

  final openrouterChat = config.openrouterApiKey == null
      ? null
      : AgentClient(
          baseUrl: Uri.parse(config.openrouterBaseUrl),
          token: config.openrouterApiKey,
          model: config.openrouterChatModel,
          cheapFallbacks: true,
          extraHeaders: const {
            'HTTP-Referer': 'http://127.0.0.1:8090',
            'X-Title': 'Maia',
          },
          maxTokens: config.openrouterMaxTokens,
        );
  final geminiChat = config.geminiApiKey == null
      ? null
      : AgentClient(
          baseUrl: Uri.parse(config.geminiBaseUrl),
          token: config.geminiApiKey,
          model: config.geminiChatModel,
        );
  final parasailChat = config.parasailApiKey == null
      ? null
      : AgentClient(
          baseUrl: Uri.parse(config.parasailBaseUrl),
          token: config.parasailApiKey,
          model: config.parasailChatModel,
        );
  final ollamaChat = config.ollamaUrl == null
      ? null
      : AgentClient(
          baseUrl: Uri.parse(config.ollamaUrl!),
          model: config.ollamaChatModel,
        );
  final gateway = config.agentUrl == null
      ? null
      : AgentClient(
          baseUrl: Uri.parse(config.agentUrl!),
          token: config.agentToken,
          model: config.agentModel,
        );

  final app = MaiaApp(
    config: config,
    db: db,
    queries: queries,
    jobs: jobs,
    embeddings: local,
    cloudEmbeddings: cloud,
    openrouterChat: openrouterChat,
    geminiChat: geminiChat,
    parasailChat: parasailChat,
    ollamaChat: ollamaChat,
    agent: gateway,
  );
  await app.ensureBootstrap();
  if (jobs != null) {
    sync = SyncClock(app.syncConnected, every: const Duration(minutes: 2))
      ..start();
  }

  final server = await io.serve(
    app.handler,
    InternetAddress.anyIPv4,
    config.port,
  );
  stdout.writeln(
    'maia-api on :${server.port} '
    '(gel=${config.gelDsn}, pgboss=${jobs != null}, '
    'embeddings=${local != null}, cloud=${cloud != null}, '
    'chat=${app.defaultChatLabel}, '
    'geocoder=${app.geocoder.provider}, queries=${queries.names.length})',
  );

  ProcessSignal.sigint.watch().listen((_) async {
    dreams?.stop();
    sync?.stop();
    await runner?.stop();
    await server.close(force: true);
    await db.close();
    exit(0);
  });
}

String _guessHackathonRoot() {
  final here = Directory.current.path;
  for (final root in [here, '$here/..', '$here/../..', '$here/../../..']) {
    if (Directory('$root/etl').existsSync() &&
        Directory('$root/swarm').existsSync()) {
      return root;
    }
  }
  return here;
}
