import 'dart:io';
import 'dart:async';

import 'package:redstone/server.dart' as app;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:connection_pool/connection_pool.dart';
import 'package:di/di.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

// Setup application log
var logger = new Logger("guestbook");

/// Create a connection pool for MongoDB
class MongoDbPool extends ConnectionPool<Db> {
  String uri;

  MongoDbPool(String this.uri, int poolSize) : super(poolSize);

  @override
  void closeConnection(Db conn) {
    conn.close();
  }

  @override
  Future<Db> openNewConnection() {
    var conn = new Db(uri);
    return conn.open().then((_) => conn);
  }
}

// Support for CORS
@app.Interceptor(r'/.*')
handleResponseHeader() {
  if (app.request.method == "OPTIONS") {
   // Overwrite the current response and interrupt the chain.
   app.response = new shelf.Response.ok(null, headers: _createCorsHeader());
   app.chain.interrupt();
  } else {
   // Process the chain and wrap the response
   app.chain.next(() => app.response.change(headers: _createCorsHeader()));
  }
}

_createCorsHeader() =>  {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-type",
  "Access-Control-Allow-Methods": "OPTIONS, HEAD, GET, POST, PUT, DELETE"
};

/// Init database connection
@app.Interceptor(r'/.*')
dbInterceptor(MongoDbPool pool) {
  pool.getConnection().then((managedConnection) {
    app.request.attributes["conn"] = managedConnection.conn;
    app.chain.next(() {
      if (app.chain.error is ConnectionException) {
        pool.releaseConnection(managedConnection, markAsInvalid: true);
      } else {
        pool.releaseConnection(managedConnection);
      }
    });
  });
}

@app.Group("/posts")
class Post {
  final String collectionName = "posts";

  @app.Route('/list')
  list(@app.Attr() Db conn) {
    logger.info("Guestbook : list posts");

    var coll = conn.collection(collectionName);
    return coll.find().toList().then((data) {
      logger.info("Got ${data.length} post(s)");
      logger.info("${data}");
      return data;
    }).catchError((e) {
      logger.warning("Unable to get post(s): ${e}");
      return [];
    });
  }

  @app.Route('/add', methods: const [app.POST])
  add(@app.Attr() Db conn, @app.Body(app.JSON) Map post) {
    logger.info("Guestbook : add post");

    var coll = conn.collection(collectionName);
    return coll.insert({"name": post["name"], "message": post["message"]}).then((data) {
      logger.info("Added post: $post");
      logger.info("${data}");
      return "Added post: $post";
    }).catchError((e) {
      logger.warning("Unable to save post: ${e}");
      return "Unable to save post";
    });
  }

  @app.Route('/delete', methods: const [app.DELETE])
  delete(@app.Attr() Db conn) {
    logger.info("Guestbook : delete post");

    var coll = conn.collection(collectionName);
    return coll.remove().then((data) {
      logger.info("Removed ${data["n"]} posts");
      logger.info("${data}");
      return "Removed ${data["n"]} posts";
    }).catchError((e) {
      logger.warning("Unable to delete posts: ${e}");
      return "Unable to delete posts";
    });
  }
}

void main() {
  // Server port assignment
  var PORT = Platform.environment['PORT'];
  var appPort = PORT != null ? int.parse(PORT) : 9090;

  // Database endpoint assignment
  var MONGODB_URI = Platform.environment['MONGODB_URI'];
  var appDB = MONGODB_URI != null ? MONGODB_URI : "mongodb://localhost/guestbook";

  // Set connection pool size
  var poolSize = 3;

  // Inject database connection pool
  app.addModule(new Module()
    ..bind(MongoDbPool, toValue: new MongoDbPool(appDB, poolSize)));

  // Setup server log
  app.setupConsoleLog();

  // Start server
  app.start(address: '127.0.0.1', port: appPort);
}

