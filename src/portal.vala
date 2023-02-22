
public class PortalManager : Object {

    private enum XdpCursorMode {
        HIDDEN = (1 << 0),
        EMBEDDED = (1 << 1),
        METADATA = (1 << 2),
    }

    private enum XdpScreencastFlags {
        NONE = 0,
        MULTIPLE = (1 << 0)
    }

    private enum XdpOutputType {
        MONITOR = (1 << 0),
        WINDOW  = (1 << 1),
        VIRTUAL = (1 << 2)
    }

    private enum XdpPersistMode  {
        NONE,
        TRANSIENT,
        PERSISTENT,
    }


    public enum Result  {
        OK,
        SESSIONFAIL,
        SOURCESFAIL,
        STARTFAIL,
        PROXYFAIL,
        REQUESTFAIL,
        CASTFAIL,
    }

    public struct SourceInfo {
        int width;
        int height;
        int x;
        int y;
        uint32 source_type;
        uint32 node_id;
        string id;
    }

    public struct CastInfo {
        int fd;
        GenericArray<SourceInfo?> sources;
    }

    private DBusProxy proxy;
    private int tcount;
    private string? restore_token;
    private string? session_handle;
    private SourceInfo[] sources;
    private int fd;
    private bool capcursor;

    public signal void completed(Result p);

    public PortalManager(string? rtoken) {
        if (rtoken != null) {
            if (!Uuid.string_is_valid(rtoken)) {
                rtoken = null;
            }
        }
        restore_token = rtoken;
        tcount = 0;
        capcursor = true;
        sources={};
        fd = -1;
    }

    public void set_token(string? t) {
        restore_token = t;
    }

    public string? get_token() {
        return restore_token;
    }

    private string make_token() {
        var str = "wayfarer_%d".printf(tcount);
        tcount++;
        return str;
    }

    public CastInfo get_cast_info() {
        GenericArray<SourceInfo?> sarry = new GenericArray<SourceInfo?>();
        foreach(var s in sources) {
            sarry.add(s);
        }
        sarry.sort((a,b) => {
                return strcmp(a.id, b.id);
            });
        return CastInfo(){fd = fd, sources = sarry};
    }

    public void close() {
        try {
            var bus =  proxy.get_connection();
            bus.call_sync(
                "org.freedesktop.portal.Desktop",
                session_handle,
                "org.freedesktop.portal.Session",
                "Close",
                null, null,
                DBusCallFlags.NONE,
                -1);
        } catch (Error e) {
            stderr.printf("Close failed %s\n", e.message);
        }
    }

    private int parse_params(Variant params, out Variant ? ht) {
        uint32 u = 0;
        ht = null;
        params.get_child(0, "u", &u);
        ht = params.get_child_value(1);
        return (int)u;
    }

    private void on_session_cb (DBusConnection conn, string? sender, string objpath,
                               string ifname, string signame, Variant params) {

        Variant ht;
        var ures = parse_params(params, out ht);
        if (ures == 0) {
            var v = ht.lookup_value("session_handle", null);
            if (v != null) {
                session_handle = v.get_string();
                select_sources_request();
            }
        } else {
            completed(Result.SESSIONFAIL);
        }
    }

    private void on_sources_cb (DBusConnection conn, string? sender, string objpath,
                               string ifname, string signame, Variant params) {
        Variant ht;
        var ures = parse_params(params, out ht);
        if (ures == 0) {
            start_request();
        } else {
            stderr.printf("Get sources cancelled\n");
            completed(Result.SOURCESFAIL);
        }
    }

    private void on_start_cb (DBusConnection conn, string? sender, string objpath,
                               string ifname, string signame, Variant params) {
        Variant ht;
        var ures = parse_params(params, out ht);
        if (ures == 0) {
            var v = ht.lookup_value("restore_token", null);
            if (v != null) {
                restore_token = v.get_string();
            }
            v = ht.lookup_value("streams", null);
            if(v != null) {
                var viter = v.iterator();
                GLib.Variant? v1 = null;
                while ((v1 = viter.next_value()) != null) {
                    SourceInfo si = {0};
                    Variant v1ht;
                    si.node_id = parse_params(v1, out v1ht);
                    v1ht.lookup("id", "s", &si.id);
                    v1ht.lookup("source_type", "u", &si.source_type);
                    v1ht.lookup("position", "(ii)", &si.x, &si.y);
                    v1ht.lookup("size", "(ii)", &si.width, &si.height);
                    sources += si;
                }
            }
            open_pw_remote_request();
        } else {
            stderr.printf("Start cancelled\n");
            completed(Result.STARTFAIL);
        }
    }

    public void acquire(bool _capcursor) {
        capcursor = _capcursor;
        try {
            proxy = new DBusProxy.for_bus_sync(BusType.SESSION,
                                               DBusProxyFlags.NONE,
                                               null,
                                                "org.freedesktop.portal.Desktop",
                                               "/org/freedesktop/portal/desktop",
                                                "org.freedesktop.portal.ScreenCast");
            create_session_request();
        } catch (Error e) {
            stderr.printf("Start session proxy error %s\n", e.message);
            completed(Result.PROXYFAIL);
        }
    }

    private void create_session_request() {
        var session_token = make_token();
        var handle_token = make_token();
        var vd = new VariantDict(null);
        vd.insert("handle_token", "s", (handle_token));
        vd.insert("session_handle_token", "s", session_token);
        Variant options = vd.end ();
        var v = new Variant.tuple({options});
        screencast_request(handle_token, "CreateSession", v, on_session_cb);
    }

    private void select_sources_request() {
        var handle_token = make_token();
        var vd = new VariantDict(null);
        vd.insert("handle_token", "s", (handle_token));
        vd.insert("types", "u", (uint32) XdpOutputType.MONITOR);
        vd.insert("multiple", "b", true);
        vd.insert("cursor_mode", "u", (uint32)((capcursor) ? XdpCursorMode.EMBEDDED:XdpCursorMode.HIDDEN));
        vd.insert("persist_mode", "u", (uint32)XdpPersistMode.PERSISTENT);
        if(restore_token != null) {
            vd.insert("restore_token", "s", restore_token);
        }
        var options = vd.end();
        var v = new Variant.tuple({new Variant.object_path(session_handle), options});
        screencast_request(handle_token, "SelectSources", v, on_sources_cb);
    }

    private void start_request() {
        var handle_token = make_token();
        var vd = new VariantDict(null);
        vd.insert("handle_token", "s", handle_token);
        Variant options = vd.end ();
        var v = new Variant.tuple({
                new Variant.object_path(session_handle),
                    new Variant.string(""),
                    options});
        screencast_request(handle_token, "Start", v, on_start_cb);
    }

    private void open_pw_remote_request() {
        UnixFDList fdl;
        var options = new Variant("a{sv}");
        var v = new Variant.tuple({new Variant.object_path(session_handle), options});
        try {
            var res = proxy.call_with_unix_fd_list_sync("OpenPipeWireRemote", v,
                                                    DBusCallFlags.NONE,
                                                    -1,
                                                    null,
                                                    out fdl);

            var fdindex = res.get_child_value(0).get_handle();
            fd = fdl.get(fdindex);
        } catch (Error e) {
            stderr.printf("Remote fd failed %s\n", e.message);
        }
        completed(Result.OK);
    }

    private void screencast_request(string handle_token, string name, Variant session_options,
                                   DBusSignalCallback signal_cb) {
        var bus =  proxy.get_connection();
        var uname = bus.get_unique_name();
        var uid = uname.replace(".","_")[1:];
        var request_path=new ObjectPath("/org/freedesktop/portal/desktop/request/%s/%s".printf(uid, handle_token));
        DBusProxy? request_proxy = null;
        try {
            request_proxy = new DBusProxy.for_bus_sync(BusType.SESSION,
                                                       DBusProxyFlags.DO_NOT_AUTO_START|
                                                       DBusProxyFlags.DO_NOT_CONNECT_SIGNALS|
                                                       DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
                                                       null,
                                                       "org.freedesktop.portal.Desktop",
                                                       request_path,
                                                       "org.freedesktop.portal.Request");
        } catch (Error e) {
            stderr.printf("Request proxy error %s\n", e.message);
            completed(Result.REQUESTFAIL);
            return;
        }

        bus.signal_subscribe(
            "org.freedesktop.portal.Desktop",
            "org.freedesktop.portal.Request",
            "Response",
            request_path,
            null,
            DBusSignalFlags.NONE, (p1,p2,p3,p4,p5,p6) => {
                signal_cb(p1,p2,p3,p4,p5,p6);});

        proxy.call.begin(name, session_options, DBusCallFlags.NONE, -1, null,(obj, res) => {
                try {
                    proxy.call.end(res);
                } catch (Error e) {
                    stderr.printf("Session failed [%s]\n", e.message);
                    completed(Result.CASTFAIL);
                }
            });
    }
}
#if CLITEST
public static int main(string?[] args) {
    var rtoken = (args.length > 1) ? args[1] : null;
    var loop = new MainLoop();
    var a = new PortalManager(rtoken);
    a.finished.connect((reult) => {
            if (result == Portal.Result.OK) {
                var ci = a.get_cast_info();
                print("Fd = %d\n", ci.fd);
                ci.sources.foreach((s) => {
                        print("si{nodeid=%u w=%d h=%d x=%d y=%d source-type=%u id=%s}\n",
                              s.node_id, s.width, s.height,s.x,s.y,s.source_type, s.id);
                    });
                print("Restore token = %s\n", a.get_token());
            } else {
                print("Portal Fail %s\n", result.to_string());
            }
            loop.quit();
        });
    Idle.add(() => {
            a.acquire(true);
            return false;
        });
    loop.run();
    return 0;
}
#endif
