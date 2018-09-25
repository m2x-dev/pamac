/*
 *  pamac-vala
 *
 *  Copyright (C) 2014-2018 Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

// i18n
const string GETTEXT_PACKAGE = "pamac";

const string update_icon_name = "pamac-tray-update";
const string noupdate_icon_name = "pamac-tray-no-update";
const string noupdate_info = _("Your system is up-to-date");

namespace Pamac {
	[DBus (name = "org.manjaro.pamac.system")]
	interface SystemDaemon : Object {
		public abstract void set_environment_variables (HashTable<string,string> variables) throws Error;
		public abstract void start_download_updates () throws Error;
		[DBus (no_reply = true)]
		public abstract void quit () throws Error;
		public signal void downloading_updates_finished ();
		public signal void write_pamac_config_finished (bool recurse, uint64 refresh_period, bool no_update_hide_icon,
														bool enable_aur, string aur_build_dir, bool check_aur_updates,
														bool download_updates);
	}

	public abstract class TrayIcon: Gtk.Application {
		Notify.Notification notification;
		Database database;
		SystemDaemon system_daemon;
		bool extern_lock;
		uint refresh_timeout_id;
		public Gtk.Menu menu;
		GLib.File lockfile;
		uint updates_nb;

		public TrayIcon () {
			application_id = "org.manjaro.pamac.tray";
			flags = ApplicationFlags.FLAGS_NONE;
		}

		void init_database () {
			var config = new Config ("/etc/pamac.conf");
			database = new Database (config);
			database.refresh_files_dbs_on_get_updates = true;
			database.config.notify["refresh-period"].connect((obj, prop) => {
				launch_refresh_timeout (database.config.refresh_period);
			});
			database.config.notify["check-aur-updates"].connect((obj, prop) => {
				check_updates ();
			});
			database.config.notify["no-update-hide-icon"].connect((obj, prop) => {
				set_icon_visible (!database.config.no_update_hide_icon);
			});
		}

		void start_system_daemon () {
			if (system_daemon == null) {
				try {
					system_daemon = Bus.get_proxy_sync (BusType.SYSTEM, "org.manjaro.pamac.system", "/org/manjaro/pamac/system");
					// Set environment variables
					system_daemon.set_environment_variables (database.config.environment_variables);
					system_daemon.downloading_updates_finished.connect (on_downloading_updates_finished);
					system_daemon.write_pamac_config_finished.connect (on_write_pamac_config_finished);
				} catch (Error e) {
					stderr.printf ("Error: %s\n", e.message);
				}
			}
		}

		void stop_system_daemon () {
			if (!check_pamac_running ()) {
				try {
					system_daemon.quit ();
				} catch (Error e) {
					stderr.printf ("Error: %s\n", e.message);
				}
			}
		}

		public abstract void init_status_icon ();

		// Create menu for right button
		void create_menu () {
			menu = new Gtk.Menu ();
			var item = new Gtk.MenuItem.with_label (_("Package Manager"));
			item.activate.connect (execute_manager);
			menu.append (item);
			item = new Gtk.MenuItem.with_mnemonic (_("_Quit"));
			item.activate.connect (this.release);
			menu.append (item);
			menu.show_all ();
		}

		public void left_clicked () {
			if (get_icon () == "pamac-tray-update") {
				execute_updater ();
			} else {
				execute_manager ();
			}
		}

		void execute_updater () {
			try {
				Process.spawn_command_line_async ("pamac-updater");
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
		}

		void execute_manager () {
			try {
				Process.spawn_command_line_async ("pamac-manager");
			} catch (SpawnError e) {
				stderr.printf ("SpawnError: %s\n", e.message);
			}
		}

		public abstract void set_tooltip (string info);

		public abstract void set_icon (string icon);

		public abstract string get_icon ();

		public abstract void set_icon_visible (bool visible);

		bool check_updates () {
			if (database.config.refresh_period != 0) {
				var updates = database.get_updates ();
				updates_nb = updates.repos_updates.length () + updates.aur_updates.length ();
				if (updates_nb == 0) {
					set_icon (noupdate_icon_name);
					set_tooltip (noupdate_info);
					set_icon_visible (!database.config.no_update_hide_icon);
					close_notification ();
				} else {
					if (!check_pamac_running () && database.config.download_updates) {
						start_system_daemon ();
						try {
							system_daemon.start_download_updates ();
						} catch (Error e) {
							stderr.printf ("Error: %s\n", e.message);
						}
					} else {
						show_or_update_notification ();
					}
				}
			}
			return true;
		}

		void on_downloading_updates_finished () {
			show_or_update_notification ();
			stop_system_daemon ();
		}

		void on_write_pamac_config_finished () {
			database.config.reload ();
		}

		void show_or_update_notification () {
			string info = ngettext ("%u available update", "%u available updates", updates_nb).printf (updates_nb);
			set_icon (update_icon_name);
			set_tooltip (info);
			set_icon_visible (true);
			if (check_pamac_running ()) {
				update_notification (info);
			} else {
				show_notification (info);
			}
		}

		void show_notification (string info) {
			try {
				close_notification ();
				notification = new Notify.Notification (_("Package Manager"), info, "system-software-update");
				notification.add_action ("default", _("Details"), execute_updater);
				notification.show ();
			} catch (Error e) {
				stderr.printf ("Notify Error: %s", e.message);
			}
		}

		void update_notification (string info) {
			try {
				if (notification != null) {
					if (notification.get_closed_reason () == -1 && notification.body != info) {
						notification.update (_("Package Manager"), info, "system-software-update");
						notification.show ();
					}
				} else {
					show_notification (info);
				}
			} catch (Error e) {
				stderr.printf ("Notify Error: %s", e.message);
			}
		}

		void close_notification () {
			try {
				if (notification != null && notification.get_closed_reason () == -1) {
					notification.close ();
					notification = null;
				}
			} catch (Error e) {
				stderr.printf ("Notify Error: %s", e.message);
			}
		}

		bool check_pamac_running () {
			Application app;
			bool run = false;
			app = new Application ("org.manjaro.pamac.manager", 0);
			try {
				app.register ();
			} catch (GLib.Error e) {
				stderr.printf ("%s\n", e.message);
			}
			run = app.get_is_remote ();
			if (run) {
				return run;
			}
			app = new Application ("org.manjaro.pamac.installer", 0);
			try {
				app.register ();
			} catch (GLib.Error e) {
				stderr.printf ("%s\n", e.message);
			}
			run = app.get_is_remote ();
			return run;
		}

		bool check_lock_and_updates () {
			if (!lockfile.query_exists ()) {
				check_updates ();
				Timeout.add (200, check_extern_lock);
				return false;
			}
			return true;
		}

		bool check_extern_lock () {
			if (lockfile.query_exists ()) {
				Timeout.add (1000, check_lock_and_updates);
				return false;
			}
			return true;
		}

		void launch_refresh_timeout (uint64 refresh_period_in_hours) {
			if (refresh_timeout_id != 0) {
				Source.remove (refresh_timeout_id);
				refresh_timeout_id = 0;
			}
			if (refresh_period_in_hours != 0) {
				refresh_timeout_id = Timeout.add_seconds ((uint) refresh_period_in_hours*3600, check_updates);
			}
		}

		public override void startup () {
			// i18n
			Intl.textdomain ("pamac");
			Intl.setlocale (LocaleCategory.ALL, "");

			init_database ();
			// if refresh period is 0, just return so tray will exit
			if (database.config.refresh_period == 0) {
				return;
			}

			base.startup ();

			extern_lock = false;
			refresh_timeout_id = 0;

			create_menu ();
			init_status_icon ();
			set_icon (noupdate_icon_name);
			set_tooltip (noupdate_info);
			set_icon_visible (!database.config.no_update_hide_icon);

			Notify.init (_("Package Manager"));

			start_system_daemon ();
			// start and stop daemon just to connect to signal
			stop_system_daemon ();

			lockfile = GLib.File.new_for_path (database.get_lockfile ());
			Timeout.add (200, check_extern_lock);
			// wait 30 seconds before check updates
			Timeout.add_seconds (30, () => {
				check_updates ();
				return false;
			});
			launch_refresh_timeout (database.config.refresh_period);

			this.hold ();
		}

		public override void activate () {
			// nothing to do
		}

	}
}
