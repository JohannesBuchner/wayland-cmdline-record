using Gtk;
using Gst;
using GLib;

public class Wayfarer : Gtk.Application {
    public enum PWSession {
        X11,
        WAYLAND,
    }
    //Gtk.ApplicationWindow window;
    private ScreenCap sc;
    private string filename;

    private PortalManager pw;
    private PortalManager.Result pw_result;
	private int fd;
    GenericArray<PortalManager.SourceInfo?> sources;
    public static bool two_is_one;
    public Wayfarer () {
        GLib.Object(application_id: "org.stronnag.wayfarer",
               flags:ApplicationFlags.FLAGS_NONE);
    }

    protected override void activate () {
        fd = -1;
        present_window();
	}
    public int present_window() {
        //var builder = new Builder.from_resource("/org/stronnag/wayfarer/wayfarer.ui");
        //window = builder.get_object ("window") as Gtk.ApplicationWindow;
        //this.add_window (window);
        //window.set_application (this);
        //window.close_request.connect( () => {
		//		clean_up();
		//		return false;
        //    });

        var dmc = Environment.get_variable("XDG_CURRENT_DESKTOP");
        if (dmc != null && dmc == "wlroots") {
            two_is_one = true;
            stderr.printf("*DBG* wlroots detected, setting `two_is_one` flag portal workaround\n");
        }

        foreach (var e in Encoders.list_profiles()) {
            if (e.is_valid) {
                print("possible encoder: %s | %s\n", e.name, e.pname);
            }
        }
        
        sc = new ScreenCap();
		sc.stream_ended.connect(() => {
				cleanup_session();
			});

        Unix.signal_add(Posix.Signal.USR1, () => {
                print("signal USR1 received, shutting down\n");
                do_stop_action();
                return Source.CONTINUE;
            });
        Unix.signal_add(Posix.Signal.TERM, () => {
                print("signal TERM received, shutting down\n");
                do_stop_action();
                return Source.CONTINUE;
            });

        sources = new GenericArray<PortalManager.SourceInfo?>();

        pw = new PortalManager("wayfarer-cmd");
        pw.completed.connect((result) => {
                print("PortalManager connected.\n");
                pw_result = result;
                if(result == PortalManager.Result.OK) {
                    print("PortalManager gave OK\n");
                    var ci = pw.get_cast_info();
                    if (ci.fd > -1  && ci.sources.length > 0 ) {
                        fd = ci.fd;
                        sources = ci.sources;
                        if (sources[0].source_type == 1 || sources[0].source_type == 0 || (two_is_one && sources[0].source_type == 2)) {
                            print("Bad news: more than one source! source_type=%u, two_is_one=%d\n", sources[0].source_type, two_is_one ? 1 : 0);
                        } else {
                            print("Good news: Got only one source!\n");
                        }
                    }
                }
                start_recording();
            });
        pw.acquire(true);
        //window.show();
        //stdin.read_line();
        
        return 0;
    }
    //private void clean_up() {
    //    quit();
    //}
    private void start_recording() {
        print("starting recording...\n");
        sc.options.capaudio = false;
        sc.options.capmouse = true;
        sc.options.framerate = 30;
        sc.options.audiorate = 48000;
        sc.options.adevice = null;
        sc.options.fd = fd;
        sc.options.mediatype = "matroska";
        sc.options.fullscreen = true;
        sc.options.dirname = "/tmp";

        print("starting capture...\n");
        var res = sc.capture(sources, out filename);
        print("starting capture... done\n");
        if (res) {
            print("output at: %s\n", filename);
        } else {
            print("Failed to record\n");
        }
    }

    private void do_stop_action() {
        stdout.printf("postprocessing...");
        sc.post_process();
	}

	private void cleanup_session() {
        stdout.printf("cleaning up...");
		if(pw_result == PortalManager.Result.OK) {
			stderr.printf("*DBG* pw.close\n");
			pw.close();
		}
		if(fd != -1) {
			stderr.printf("*DBG* close FD %d\n", fd);
			Posix.close(fd);
			fd = -1;
		}
	}

    public static int main (string[] args) {
        //Gtk.init();
        MainLoop loop = new MainLoop ();
        Gst.init(ref args);
        Encoders.Init();

        Wayfarer app = new Wayfarer();
        app.run(args);
        loop.run ();
        return 0;
    }
}
