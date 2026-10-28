#include <gtk/gtk.h>
#include <json-glib/json-glib.h>
#include <unistd.h>

#define APK "/sbin/apk"
#define PLATFORM "/usr/share/pinecone/platform-packages.txt"
#define REPOSITORIES "/etc/apk/repositories"
#define DISABLED_SOURCE "# Disabled by Packages: "
#define PAGE_SIZE 10
#define LOG_LIMIT 65536

typedef enum { HOME, SOURCES, UPDATES, INSTALLED, SEARCH, SECTION, DETAILS, QUEUE } Page;
typedef enum { LOAD_INSTALLED, QUERY, DETAIL_QUERY, REFRESH, PLAN, COMMIT } Operation;
typedef enum { INSTALL_PACKAGE, REMOVE_PACKAGE, UPDATE_PACKAGE } Action;
typedef struct { const gchar *name, *title, *summary, *icon; guint section; } Featured;

/* Editorial categories are separate from APK repository metadata. */
static const Featured featured[] = {
    {"gnome-calculator", "Calculator", "Everyday and scientific calculations", "accessories-calculator-symbolic", 0},
    {"mousepad", "Mousepad", "A compact text editor", "accessories-text-editor-symbolic", 0},
    {"evince", "Document Viewer", "PDFs and documents", "x-office-document-symbolic", 0},
    {"eog", "Image Viewer", "Browse photos and images", "image-x-generic-symbolic", 1},
    {"file-roller", "Archive Manager", "Open and create archives", "package-x-generic-symbolic", 1},
    {"thunar", "Files", "Browse the guest filesystem", "folder-symbolic", 1},
    {"htop", "htop", "Interactive terminal process viewer", "utilities-terminal-symbolic", 2},
    {"nano", "nano", "Terminal text editor", "utilities-terminal-symbolic", 2},
    {"tree", "tree", "Directory listings in a tree", "folder-symbolic", 2},
    {"git", "Git", "Version control tools", "applications-engineering-symbolic", 3},
    {"curl", "curl", "Transfer data from URLs", "network-transmit-receive-symbolic", 3},
};
static const gchar *sections[] = {"Productivity", "Files & Images", "Terminal Tools", "Development"};
static const gchar *section_icons[] = {"x-office-document-symbolic", "folder-pictures-symbolic",
    "utilities-terminal-symbolic", "applications-engineering-symbolic"};
static const gchar *page_titles[] = {"Discover", "Sources", "Updates", "Installed", "Search", "Categories", "Package", "Queue"};
static const gchar *action_names[] = {"Install", "Remove", "Update"};

typedef struct {
    GtkWidget *window, *header, *body, *scroll, *nav, *refresh, *back, *queue_button;
    GtkWidget *status, *spinner, *log, *tabs[5];
    GHashTable *installed, *protected, *queue, *details_cache;
    JsonArray *installed_records, *results;
    JsonObject *detail;
    GSubprocess *process;
    GDataInputStream *stream;
    GString *transaction_log;
    gchar *package, *query, *source_contents, *source_etag, *post_load_notice;
    Page page, return_page;
    Action queue_action;
    Operation operation;
    guint offset, section, installed_filter;
    gboolean busy, updating_tabs, show_categories;
} App;
static App app;
static void render(void);
static void navigate(Page page);
static void execute(const gchar *const *argv, Operation operation, const gchar *status);
static void load_installed(void);
static void run_query(void);
static void transaction_command(Operation operation);

static gboolean valid_package(const gchar *name) {
    if (!name || !g_ascii_isalnum(*name) || strlen(name) > 200) return FALSE;
    for (const gchar *p = name; *p; p++)
        if (!g_ascii_isalnum(*p) && !strchr("+_.-", *p)) return FALSE;
    return TRUE;
}

static GHashTable *parse_platform(const gchar *contents, GError **error) {
    GHashTable *result = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_auto(GStrv) lines = g_strsplit(contents, "\n", -1);
    for (guint i = 0; lines[i]; i++) {
        if (!*lines[i]) continue;
        gchar *separator = strchr(lines[i], '=');
        if (!separator || !separator[1]) goto invalid;
        *separator = '\0';
        if (!valid_package(lines[i])) goto invalid;
        g_hash_table_add(result, g_strdup(lines[i]));
    }
    if (g_hash_table_size(result) == 0) goto invalid;
    return result;
invalid:
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "The Pinecone platform manifest is invalid.");
    g_hash_table_unref(result);
    return NULL;
}

static const gchar *string_field(JsonObject *object, const gchar *key) {
    JsonNode *node = json_object_get_member(object, key);
    if (!node || !JSON_NODE_HOLDS_VALUE(node) || json_node_get_value_type(node) != G_TYPE_STRING) return NULL;
    return json_node_get_string(node);
}

static JsonArray *parse_packages(const gchar *contents, GError **error) {
    g_autoptr(JsonParser) parser = json_parser_new();
    if (!json_parser_load_from_data(parser, contents, -1, error)) return NULL;
    JsonNode *root = json_parser_get_root(parser);
    if (!root || !JSON_NODE_HOLDS_ARRAY(root)) goto invalid;
    JsonArray *array = json_node_get_array(root);
    for (guint i = 0; i < json_array_get_length(array); i++) {
        JsonNode *item = json_array_get_element(array, i);
        if (!JSON_NODE_HOLDS_OBJECT(item)) goto invalid;
        JsonObject *object = json_node_get_object(item);
        const gchar *name = string_field(object, "name");
        if ((!valid_package(name) && !(name && name[0] == '.' && valid_package(name + 1))) ||
            !string_field(object, "version") || !string_field(object, "description")) goto invalid;
    }
    return json_array_ref(array);
invalid:
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid package data returned by APK.");
    return NULL;
}

static gboolean valid_source(const gchar *url) {
    if (!url || !*url || strlen(url) > 2048 || strpbrk(url, " \t\r\n")) return FALSE;
    g_autoptr(GUri) uri = g_uri_parse(url, G_URI_FLAGS_NONE, NULL);
    if (!uri || !g_uri_get_host(uri) || !*g_uri_get_host(uri) ||
        g_uri_get_userinfo(uri) || g_uri_get_fragment(uri) || g_uri_get_query(uri)) return FALSE;
    const gchar *scheme = g_uri_get_scheme(uri);
    return scheme && (!strcmp(scheme, "https") || !strcmp(scheme, "http"));
}

static void set_status(const gchar *text) { gtk_label_set_text(GTK_LABEL(app.status), text); }

static void update_queue_badge(void) {
    guint count = g_hash_table_size(app.queue);
    g_autofree gchar *title = g_strdup_printf("Review queue (%u)", count);
    gtk_widget_set_tooltip_text(app.queue_button, title);
    atk_object_set_name(gtk_widget_get_accessible(app.queue_button), title);
    GtkStyleContext *style = gtk_widget_get_style_context(app.queue_button);
    if (count) gtk_style_context_add_class(style, "suggested-action");
    else gtk_style_context_remove_class(style, "suggested-action");
}

static void set_busy(gboolean busy, const gchar *status) {
    app.busy = busy;
    gtk_widget_set_sensitive(app.body, !busy);
    gtk_widget_set_sensitive(app.nav, !busy);
    gtk_widget_set_sensitive(app.refresh, !busy);
    gtk_widget_set_sensitive(app.back, !busy);
    gtk_widget_set_sensitive(app.queue_button, !busy);
    if (busy) gtk_spinner_start(GTK_SPINNER(app.spinner));
    else gtk_spinner_stop(GTK_SPINNER(app.spinner));
    set_status(status);
}

static void show_log(const gchar *output, const gchar *errors) {
    g_autofree gchar *text = g_strconcat(output ? output : "", errors ? errors : "", NULL);
    const gchar *start = text;
    if (strlen(text) > LOG_LIMIT) {
        start = text + strlen(text) - LOG_LIMIT;
        while (*start && ((*start & 0xc0) == 0x80)) start++;
    }
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(app.log)), start, -1);
}

static GtkWidget *label(const gchar *text, const gchar *style) {
    GtkWidget *widget = gtk_label_new(text ? text : "");
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_line_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(widget), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(widget), 28);
    gtk_widget_set_hexpand(widget, TRUE);
    if (style) gtk_style_context_add_class(gtk_widget_get_style_context(widget), style);
    return widget;
}

static GtkWidget *icon_button(const gchar *icon, const gchar *tooltip) {
    GtkWidget *button = gtk_button_new_from_icon_name(icon, GTK_ICON_SIZE_BUTTON);
    gtk_widget_set_tooltip_text(button, tooltip);
    atk_object_set_name(gtk_widget_get_accessible(button), tooltip);
    return button;
}

static void append(GtkWidget *widget) { gtk_box_pack_start(GTK_BOX(app.body), widget, FALSE, FALSE, 0); }

static void heading(const gchar *title, const gchar *subtitle) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5);
    gtk_container_set_border_width(GTK_CONTAINER(box), 16);
    gtk_box_pack_start(GTK_BOX(box), label(title, "title"), FALSE, FALSE, 0);
    if (subtitle) gtk_box_pack_start(GTK_BOX(box), label(subtitle, "dim-label"), FALSE, FALSE, 0);
    append(box);
}

static void notice(const gchar *text) {
    GtkWidget *widget = label(text, "dim-label");
    gtk_widget_set_margin_start(widget, 16);
    gtk_widget_set_margin_end(widget, 16);
    gtk_widget_set_margin_top(widget, 12);
    gtk_widget_set_margin_bottom(widget, 12);
    append(widget);
}

static GtkWidget *row_button(const gchar *title, const gchar *subtitle, const gchar *icon, const gchar *trailing) {
    GtkWidget *button = gtk_button_new();
    gtk_style_context_add_class(gtk_widget_get_style_context(button), "package-row");
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_container_set_border_width(GTK_CONTAINER(row), 8);
    GtkWidget *image = gtk_image_new_from_icon_name(icon, GTK_ICON_SIZE_LARGE_TOOLBAR);
    gtk_widget_set_size_request(image, 32, 32);
    gtk_box_pack_start(GTK_BOX(row), image, FALSE, FALSE, 0);
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_pack_start(GTK_BOX(texts), label(title, "package-name"), FALSE, FALSE, 0);
    if (subtitle && *subtitle) {
        GtkWidget *description = label(subtitle, "dim-label");
        gtk_label_set_lines(GTK_LABEL(description), 2);
        gtk_label_set_ellipsize(GTK_LABEL(description), PANGO_ELLIPSIZE_END);
        gtk_box_pack_start(GTK_BOX(texts), description, FALSE, FALSE, 0);
    }
    gtk_box_pack_start(GTK_BOX(row), texts, TRUE, TRUE, 0);
    gtk_box_pack_end(GTK_BOX(row), gtk_image_new_from_icon_name(trailing, GTK_ICON_SIZE_MENU), FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(button), row);
    return button;
}

static const Featured *find_featured(const gchar *name) {
    for (guint i = 0; i < G_N_ELEMENTS(featured); i++)
        if (!strcmp(featured[i].name, name)) return &featured[i];
    return NULL;
}

static void open_package(GtkButton *button, gpointer unused) {
    (void)unused;
    const gchar *name = g_object_get_data(G_OBJECT(button), "package");
    if (app.busy || !valid_package(name)) return;
    g_free(app.package);
    app.package = g_strdup(name);
    app.return_page = app.page;
    g_clear_pointer(&app.detail, json_object_unref);
    JsonObject *cached = app.return_page == UPDATES ? NULL : g_hash_table_lookup(app.details_cache, app.package);
    if (cached) app.detail = json_object_ref(cached);
    app.page = DETAILS;
    render();
    if (cached) return;
    gboolean local = g_hash_table_contains(app.installed, app.package) && app.return_page != UPDATES;
    const gchar *argv[] = {APK, "--no-network", "--repositories-file", local ? "/dev/null" : REPOSITORIES,
        "query", "--from", local ? "installed" : "system", "--format", "json", "--fields",
        "name,version,description,license,url,installed-size,file-size,depends,repositories,arch",
        "--match", "name", "--", app.package, NULL};
    execute(argv, DETAIL_QUERY, "Reading package details...");
}

static void package_row(const gchar *name, const gchar *description) {
    const Featured *item = find_featured(name);
    const gchar *installed = g_hash_table_lookup(app.installed, name);
    gboolean queued = g_hash_table_contains(app.queue, name);
    const gchar *trailing = queued ? "list-add-symbolic" : installed ? "object-select-symbolic" : "go-next-symbolic";
    g_autofree gchar *subtitle = installed ? g_strdup_printf("%s  /  Installed %s", description, installed) : g_strdup(description);
    GtkWidget *button = row_button(item ? item->title : name, subtitle,
        item ? item->icon : "package-x-generic-symbolic", trailing);
    g_object_set_data_full(G_OBJECT(button), "package", g_strdup(name), g_free);
    g_signal_connect(button, "clicked", G_CALLBACK(open_package), NULL);
    append(button);
}

static void category_selected(GtkButton *button, gpointer unused) {
    (void)unused;
    app.section = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "section"));
    navigate(SECTION);
}

static void categories_clicked(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    app.show_categories = !app.show_categories;
    render();
}

static void render_home(void) {
    heading("Pinecone Packages", "Software for your Alpine desktop");
    GtkWidget *categories = row_button(app.show_categories ? "Featured" : "Categories",
        app.show_categories ? "Selected apps and utilities" : "Productivity, files, terminal and development",
        "view-grid-symbolic", "go-next-symbolic");
    g_signal_connect(categories, "clicked", G_CALLBACK(categories_clicked), NULL);
    append(categories);
    if (app.show_categories) {
        for (guint i = 0; i < G_N_ELEMENTS(sections); i++) {
            GtkWidget *button = row_button(sections[i], NULL, section_icons[i], "go-next-symbolic");
            g_object_set_data(G_OBJECT(button), "section", GUINT_TO_POINTER(i));
            g_signal_connect(button, "clicked", G_CALLBACK(category_selected), NULL);
            append(button);
        }
    } else {
        heading("Featured", NULL);
        for (guint i = 0; i < 6; i++) package_row(featured[i].name, featured[i].summary);
        notice("Availability and compatibility are checked against your configured sources.");
    }
}

static void search_requested(GtkWidget *widget, gpointer unused) {
    (void)unused;
    g_free(app.query);
    app.query = g_strdup(gtk_entry_get_text(GTK_ENTRY(widget)));
    app.offset = 0;
    gtk_window_set_focus(GTK_WINDOW(app.window), NULL);
    run_query();
}

static void change_page(GtkButton *button, gpointer direction) {
    (void)button;
    if (GPOINTER_TO_INT(direction) < 0) app.offset -= MIN(app.offset, PAGE_SIZE);
    else app.offset += PAGE_SIZE;
    render();
}

static gboolean include_installed(const gchar *name) {
    gboolean bundled = g_hash_table_contains(app.protected, name);
    return app.installed_filter == 2 || (app.installed_filter == 1 ? bundled : !bundled);
}

static void filter_changed(GtkComboBox *combo, gpointer unused) {
    (void)unused;
    app.installed_filter = (guint)gtk_combo_box_get_active(combo);
    app.offset = 0;
    render();
}

static void render_results(void) {
    JsonArray *records = app.page == INSTALLED ? app.installed_records : app.results;
    if (app.page == SEARCH) {
        GtkWidget *entry = gtk_search_entry_new();
        gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "Package name");
        gtk_entry_set_max_length(GTK_ENTRY(entry), 100);
        gtk_entry_set_text(GTK_ENTRY(entry), app.query ? app.query : "");
        gtk_widget_set_margin_start(entry, 12);
        gtk_widget_set_margin_end(entry, 12);
        gtk_widget_set_margin_top(entry, 12);
        gtk_widget_set_margin_bottom(entry, 12);
        g_signal_connect(entry, "activate", G_CALLBACK(search_requested), NULL);
        append(entry);
        if (!app.query || !*app.query) { notice("Search Alpine packages"); return; }
    } else if (app.page == INSTALLED) {
        GtkWidget *filter = gtk_combo_box_text_new();
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(filter), "Added packages");
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(filter), "Pinecone system");
        gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(filter), "All installed");
        gtk_combo_box_set_active(GTK_COMBO_BOX(filter), (gint)app.installed_filter);
        gtk_widget_set_margin_start(filter, 12);
        gtk_widget_set_margin_end(filter, 12);
        gtk_widget_set_margin_top(filter, 12);
        g_signal_connect(filter, "changed", G_CALLBACK(filter_changed), NULL);
        append(filter);
    } else heading("Available updates", "Pinecone system packages remain pinned.");
    if (!records) { notice("No package data yet"); return; }
    g_autoptr(GHashTable) shown = g_hash_table_new(g_str_hash, g_str_equal);
    guint count = 0;
    for (guint i = 0; i < json_array_get_length(records); i++) {
        JsonObject *object = json_array_get_object_element(records, i);
        const gchar *name = string_field(object, "name");
        if (name[0] == '.' || g_hash_table_contains(shown, name)) continue;
        g_hash_table_add(shown, (gpointer)name);
        if (app.page == INSTALLED && !include_installed(name)) continue;
        if (app.page == UPDATES && g_hash_table_contains(app.protected, name)) continue;
        if (count >= app.offset && count < app.offset + PAGE_SIZE)
            package_row(name, string_field(object, "description"));
        count++;
    }
    if (!count) notice(app.page == UPDATES ? "No updates available in the cached indexes." :
        app.page == INSTALLED ? "No added packages yet." : "No matching packages. Try refreshing your sources.");
    else {
        GtkWidget *pager = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_container_set_border_width(GTK_CONTAINER(pager), 12);
        g_autofree gchar *summary = g_strdup_printf("%u-%u of %u", MIN(app.offset + 1, count), MIN(app.offset + PAGE_SIZE, count), count);
        gtk_box_pack_start(GTK_BOX(pager), label(summary, "dim-label"), TRUE, TRUE, 0);
        GtkWidget *prev = icon_button("go-previous-symbolic", "Previous page");
        GtkWidget *next = icon_button("go-next-symbolic", "Next page");
        gtk_widget_set_sensitive(prev, app.offset > 0);
        gtk_widget_set_sensitive(next, app.offset + PAGE_SIZE < count);
        g_signal_connect(prev, "clicked", G_CALLBACK(change_page), GINT_TO_POINTER(-1));
        g_signal_connect(next, "clicked", G_CALLBACK(change_page), GINT_TO_POINTER(1));
        gtk_box_pack_start(GTK_BOX(pager), prev, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(pager), next, FALSE, FALSE, 0);
        append(pager);
    }
}

static gboolean queue_change(const gchar *name, Action action, GError **error) {
    if (!valid_package(name) || g_hash_table_contains(app.protected, name)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "Pinecone system packages are protected.");
        return FALSE;
    }
    if (g_hash_table_size(app.queue) && action != app.queue_action) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_BUSY,
            "Apply or clear the current queue before queuing a different transaction type.");
        return FALSE;
    }
    app.queue_action = action;
    g_hash_table_add(app.queue, g_strdup(name));
    return TRUE;
}

static void queue_selected(GtkButton *button, gpointer action) {
    (void)button;
    g_autoptr(GError) error = NULL;
    if (!queue_change(app.package, GPOINTER_TO_INT(action), &error)) { set_status(error->message); return; }
    render();
    set_status("Added to queue");
}

static void remove_queued(GtkButton *button, gpointer unused) {
    (void)unused;
    const gchar *name = g_object_get_data(G_OBJECT(button), "package");
    g_hash_table_remove(app.queue, name);
    render();
}

static void field(const gchar *title, const gchar *value) {
    if (!value || !*value) return;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_container_set_border_width(GTK_CONTAINER(box), 12);
    gtk_box_pack_start(GTK_BOX(box), label(title, "dim-label"), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), label(value, NULL), FALSE, FALSE, 0);
    append(box);
}

static void array_field(const gchar *key, const gchar *title) {
    JsonNode *node = json_object_get_member(app.detail, key);
    if (!node || !JSON_NODE_HOLDS_ARRAY(node)) return;
    JsonArray *array = json_node_get_array(node);
    g_autoptr(GString) text = g_string_new(NULL);
    for (guint i = 0; i < json_array_get_length(array); i++) {
        JsonNode *item = json_array_get_element(array, i);
        if (JSON_NODE_HOLDS_VALUE(item) && json_node_get_value_type(item) == G_TYPE_STRING) {
            if (text->len) g_string_append_c(text, '\n');
            g_string_append(text, json_node_get_string(item));
        }
    }
    field(title, text->str);
}

static void size_field(const gchar *key, const gchar *title) {
    JsonNode *node = json_object_get_member(app.detail, key);
    if (!node || !JSON_NODE_HOLDS_VALUE(node) || json_node_get_value_type(node) != G_TYPE_INT64) return;
    gint64 size = json_node_get_int(node);
    if (size < 0) return;
    g_autofree gchar *text = g_format_size((guint64)size);
    field(title, text);
}

static void render_detail(void) {
    const Featured *item = find_featured(app.package);
    heading(item ? item->title : app.package, app.package);
    if (!app.detail) { notice("Package information is unavailable until its source index is loaded."); return; }
    field("Description", string_field(app.detail, "description"));
    gboolean installed = g_hash_table_contains(app.installed, app.package);
    gboolean protected = g_hash_table_contains(app.protected, app.package);
    if (protected) notice("Included in Pinecone. This version is pinned to preserve the system runtime.");
    else if (g_hash_table_contains(app.queue, app.package)) {
        g_autofree gchar *queued = g_strdup_printf("Queued to %s", action_names[app.queue_action]);
        GtkWidget *button = gtk_button_new_with_label(queued);
        g_object_set_data_full(G_OBJECT(button), "package", g_strdup(app.package), g_free);
        gtk_widget_set_tooltip_text(button, "Remove from queue");
        g_signal_connect(button, "clicked", G_CALLBACK(remove_queued), NULL);
        append(button);
    } else {
        Action action = installed ? (app.return_page == UPDATES ? UPDATE_PACKAGE : REMOVE_PACKAGE) : INSTALL_PACKAGE;
        g_autofree gchar *title = g_strdup_printf("Queue %s", action_names[action]);
        GtkWidget *button = gtk_button_new_with_label(title);
        gtk_style_context_add_class(gtk_widget_get_style_context(button), action == REMOVE_PACKAGE ? "destructive-action" : "suggested-action");
        gtk_widget_set_margin_start(button, 12);
        gtk_widget_set_margin_end(button, 12);
        g_signal_connect(button, "clicked", G_CALLBACK(queue_selected), GINT_TO_POINTER(action));
        append(button);
    }
    field("Package version", string_field(app.detail, "version"));
    field("Installed version", g_hash_table_lookup(app.installed, app.package));
    size_field("file-size", "Download size");
    size_field("installed-size", "Installed size");
    field("License", string_field(app.detail, "license"));
    field("Architecture", string_field(app.detail, "arch"));
    field("Website", string_field(app.detail, "url"));
    array_field("repositories", "Sources");
    array_field("depends", "Dependencies");
}

static void review_queue(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    transaction_command(PLAN);
}

static void clear_queue(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    g_hash_table_remove_all(app.queue);
    render();
}

static void render_queue(void) {
    guint count = g_hash_table_size(app.queue);
    g_autofree gchar *title = g_strdup_printf("%u queued package%s", count, count == 1 ? "" : "s");
    heading(title, count ? action_names[app.queue_action] : NULL);
    if (!count) { notice("Your queue is empty."); return; }
    GList *keys = g_hash_table_get_keys(app.queue);
    keys = g_list_sort(keys, (GCompareFunc)g_strcmp0);
    for (GList *p = keys; p; p = p->next) {
        GtkWidget *button = row_button(p->data, action_names[app.queue_action], "package-x-generic-symbolic", "list-remove-symbolic");
        gtk_widget_set_tooltip_text(button, "Remove from queue");
        g_object_set_data_full(G_OBJECT(button), "package", g_strdup(p->data), g_free);
        g_signal_connect(button, "clicked", G_CALLBACK(remove_queued), NULL);
        append(button);
    }
    g_list_free(keys);
    GtkWidget *review = gtk_button_new_with_label("Review Changes");
    gtk_style_context_add_class(gtk_widget_get_style_context(review), "suggested-action");
    g_signal_connect(review, "clicked", G_CALLBACK(review_queue), NULL);
    append(review);
    GtkWidget *clear = gtk_button_new_with_label("Clear Queue");
    g_signal_connect(clear, "clicked", G_CALLBACK(clear_queue), NULL);
    append(clear);
}

static gboolean read_sources(GError **error) {
    g_autoptr(GFile) file = g_file_new_for_path(REPOSITORIES);
    g_clear_pointer(&app.source_contents, g_free);
    g_clear_pointer(&app.source_etag, g_free);
    return g_file_load_contents(file, NULL, &app.source_contents, NULL, &app.source_etag, error);
}

static gboolean replace_sources(GFile *file, const gchar *contents, const gchar *etag, GError **error) {
    /* Compare-and-replace preserves another tool's edits instead of overwriting them. */
    if (!etag) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Reload sources before editing.");
        return FALSE;
    }
    return g_file_replace_contents(file, contents, strlen(contents), etag, TRUE,
        G_FILE_CREATE_PRIVATE, NULL, NULL, error);
}

static gboolean write_sources(const gchar *contents, GError **error) {
    g_autoptr(GFile) file = g_file_new_for_path(REPOSITORIES);
    return replace_sources(file, contents, app.source_etag, error);
}

static gchar *toggled_source(const gchar *original, guint selected) {
    g_auto(GStrv) lines = g_strsplit(original, "\n", -1);
    if (selected >= g_strv_length(lines)) return NULL;
    const gchar *selected_url = g_str_has_prefix(lines[selected], DISABLED_SOURCE) ?
        lines[selected] + strlen(DISABLED_SOURCE) : lines[selected];
    if (!valid_source(selected_url)) return NULL;
    GString *contents = g_string_new(NULL);
    for (guint i = 0; lines[i]; i++) {
        const gchar *line = lines[i];
        if (i) g_string_append_c(contents, '\n');
        if (i == selected) {
            if (g_str_has_prefix(line, DISABLED_SOURCE)) line += strlen(DISABLED_SOURCE);
            else g_string_append(contents, DISABLED_SOURCE);
        }
        g_string_append(contents, line);
    }
    return g_string_free(contents, FALSE);
}

static void toggle_source(GtkButton *button, gpointer unused) {
    (void)unused;
    guint selected = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "line"));
    g_autofree gchar *contents = toggled_source(app.source_contents, selected);
    if (!contents) { set_status("This source entry must be edited outside Packages."); return; }
    g_autoptr(GError) error = NULL;
    if (!write_sources(contents, &error)) {
        render();
        set_status(error->message);
        return;
    }
    g_hash_table_remove_all(app.details_cache);
    render();
    set_status("Sources saved. Refresh to load current indexes.");
}

static void add_source(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    GtkWidget *dialog = gtk_dialog_new_with_buttons("Add Source", GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
        "Cancel", GTK_RESPONSE_CANCEL, "Add", GTK_RESPONSE_ACCEPT, NULL);
    gtk_window_set_default_size(GTK_WINDOW(dialog), 300, 180);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    gtk_container_set_border_width(GTK_CONTAINER(content), 12);
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "https://example.org/alpine/edge/main");
    gtk_entry_set_input_purpose(GTK_ENTRY(entry), GTK_INPUT_PURPOSE_URL);
    gtk_entry_set_max_length(GTK_ENTRY(entry), 2048);
    gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
    gtk_box_pack_start(GTK_BOX(content), entry, FALSE, FALSE, 8);
    GtkWidget *message = label("Only packages signed by trusted keys can be installed.", "dim-label");
    gtk_box_pack_start(GTK_BOX(content), message, FALSE, FALSE, 8);
    gtk_widget_show_all(dialog);
    while (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        g_autofree gchar *url = g_strdup(gtk_entry_get_text(GTK_ENTRY(entry)));
        g_strstrip(url);
        if (!valid_source(url)) { gtk_label_set_text(GTK_LABEL(message), "Enter an HTTP or HTTPS repository URL without credentials, query or fragment."); continue; }
        g_auto(GStrv) lines = g_strsplit(app.source_contents, "\n", -1);
        gboolean duplicate = FALSE;
        for (guint i = 0; lines[i]; i++) {
            const gchar *line = g_str_has_prefix(lines[i], DISABLED_SOURCE) ? lines[i] + strlen(DISABLED_SOURCE) : lines[i];
            if (!strcmp(line, url)) duplicate = TRUE;
        }
        if (duplicate) { gtk_label_set_text(GTK_LABEL(message), "That source is already listed."); continue; }
        g_autofree gchar *updated = g_strdup_printf("%s%s%s\n", app.source_contents,
            g_str_has_suffix(app.source_contents, "\n") ? "" : "\n", url);
        g_autoptr(GError) error = NULL;
        if (!write_sources(updated, &error)) { gtk_label_set_text(GTK_LABEL(message), error->message); continue; }
        g_hash_table_remove_all(app.details_cache);
        break;
    }
    gtk_widget_destroy(dialog);
    render();
}

static void render_sources(void) {
    heading("Package sources", "Signed Alpine repositories");
    g_autoptr(GError) error = NULL;
    if (!read_sources(&error)) { notice(error->message); return; }
    g_auto(GStrv) lines = g_strsplit(app.source_contents, "\n", -1);
    for (guint i = 0; lines[i]; i++) {
        gboolean disabled = g_str_has_prefix(lines[i], DISABLED_SOURCE);
        const gchar *url = disabled ? lines[i] + strlen(DISABLED_SOURCE) : lines[i];
        if (!*url || (*url == '#' && !disabled)) continue;
        GtkWidget *row = gtk_check_button_new();
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(row), !disabled);
        gtk_widget_set_margin_start(row, 12);
        gtk_widget_set_margin_end(row, 12);
        GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        gtk_container_set_border_width(GTK_CONTAINER(labels), 8);
        gtk_box_pack_start(GTK_BOX(labels), label(disabled ? "Disabled" : "Enabled", "package-name"), FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(labels), label(url, NULL), FALSE, FALSE, 0);
        gtk_container_add(GTK_CONTAINER(row), labels);
        gtk_widget_set_tooltip_text(row, disabled ? "Enable source" : "Disable source");
        gtk_widget_set_sensitive(row, valid_source(url));
        g_object_set_data(G_OBJECT(row), "line", GUINT_TO_POINTER(i));
        g_signal_connect(row, "toggled", G_CALLBACK(toggle_source), NULL);
        append(row);
    }
    GtkWidget *add = gtk_button_new_with_label("Add Source");
    g_signal_connect(add, "clicked", G_CALLBACK(add_source), NULL);
    append(add);
    notice("Signing keys and Pinecone version pins are not changed when you add a source.");
}

static void render(void) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(app.body));
    for (GList *p = children; p; p = p->next) gtk_widget_destroy(p->data);
    g_list_free(children);
    gtk_header_bar_set_title(GTK_HEADER_BAR(app.header), page_titles[app.page]);
    gtk_widget_set_visible(app.back, app.page > SEARCH);
    app.updating_tabs = TRUE;
    for (guint i = 0; i < 5; i++) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(app.tabs[i]), app.page == (Page)i);
    app.updating_tabs = FALSE;
    update_queue_badge();
    switch (app.page) {
    case HOME: render_home(); break;
    case SOURCES: render_sources(); break;
    case UPDATES: case INSTALLED: case SEARCH: render_results(); break;
    case SECTION:
        heading(sections[app.section], NULL);
        for (guint i = 0; i < G_N_ELEMENTS(featured); i++)
            if (featured[i].section == app.section) package_row(featured[i].name, featured[i].summary);
        break;
    case DETAILS: render_detail(); break;
    case QUEUE: render_queue(); break;
    }
    gtk_widget_show_all(app.body);
    gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(app.scroll)), 0);
}

static void navigate(Page page) {
    if (app.busy) return;
    app.page = page;
    app.offset = 0;
    if (page == UPDATES || page == SEARCH) g_clear_pointer(&app.results, json_array_unref);
    render();
    set_status("Ready");
    if (page == UPDATES || (page == SEARCH && app.query && *app.query)) run_query();
}

static void tab_clicked(GtkButton *button, gpointer page) {
    (void)button;
    if (!app.updating_tabs) navigate(GPOINTER_TO_INT(page));
}

static void back_clicked(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    navigate(app.page == DETAILS ? app.return_page : HOME);
}

static void queue_clicked(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    navigate(QUEUE);
}

static GPtrArray *transaction_argv(Operation operation) {
    GPtrArray *args = g_ptr_array_new_with_free_func(g_free);
    const gchar *base[] = {APK, "--no-progress", "--timeout", "30", "--wait", "5",
        app.queue_action == REMOVE_PACKAGE ? "del" : "add", operation == PLAN ? "--simulate" : "--no-interactive"};
    for (guint i = 0; i < G_N_ELEMENTS(base); i++) g_ptr_array_add(args, g_strdup(base[i]));
    if (app.queue_action == UPDATE_PACKAGE) g_ptr_array_add(args, g_strdup("--upgrade"));
    g_ptr_array_add(args, g_strdup("--"));
    GList *keys = g_hash_table_get_keys(app.queue);
    keys = g_list_sort(keys, (GCompareFunc)g_strcmp0);
    for (GList *p = keys; p; p = p->next) g_ptr_array_add(args, g_strdup(p->data));
    g_list_free(keys);
    g_ptr_array_add(args, NULL);
    return args;
}

static void transaction_command(Operation operation) {
    if (app.busy || !g_hash_table_size(app.queue)) return;
    g_autoptr(GPtrArray) args = transaction_argv(operation);
    execute((const gchar *const *)args->pdata, operation, operation == PLAN ? "Resolving dependencies..." : "Applying changes...");
}

static void confirm_plan(const gchar *text) {
    GtkWidget *dialog = gtk_dialog_new_with_buttons("Confirm Changes", GTK_WINDOW(app.window), GTK_DIALOG_MODAL,
        "Cancel", GTK_RESPONSE_CANCEL, "Apply", GTK_RESPONSE_ACCEPT, NULL);
    gtk_window_set_default_size(GTK_WINDOW(dialog), 320, 420);
    GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    GtkWidget *view = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), text, -1);
    gtk_container_add(GTK_CONTAINER(scroll), view);
    gtk_box_pack_start(GTK_BOX(gtk_dialog_get_content_area(GTK_DIALOG(dialog))), scroll, TRUE, TRUE, 12);
    gtk_widget_show_all(dialog);
    gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    if (response == GTK_RESPONSE_ACCEPT) transaction_command(COMMIT);
    else set_status("Queue preserved. No changes applied.");
}

static void process_result(gboolean success, const gchar *output, const gchar *errors) {
    Operation operation = app.operation;
    g_clear_object(&app.stream);
    g_clear_object(&app.process);
    set_busy(FALSE, success ? "Ready" : "Operation failed. Open Activity for details.");
    if (!success) {
        show_log(output, errors);
        if (operation == COMMIT) {
            /* APK can make partial progress before an error. Reload actual state. */
            g_hash_table_remove_all(app.details_cache);
            g_free(app.post_load_notice);
            app.post_load_notice = g_strdup("Transaction failed. Installed state reloaded; see Activity. Queue retained.");
            load_installed();
        }
        return;
    }
    if (operation == PLAN) {
        confirm_plan(output);
    } else if (operation == COMMIT || operation == REFRESH) {
        g_hash_table_remove_all(app.details_cache);
        if (operation == COMMIT) g_hash_table_remove_all(app.queue);
        load_installed();
    } else {
        g_autoptr(GError) error = NULL;
        g_autoptr(JsonArray) packages = parse_packages(output, &error);
        if (!packages) { set_status(error->message); return; }
        if (operation == LOAD_INSTALLED) {
            g_clear_pointer(&app.installed_records, json_array_unref);
            app.installed_records = json_array_ref(packages);
            g_hash_table_remove_all(app.installed);
            for (guint i = 0; i < json_array_get_length(packages); i++) {
                JsonObject *object = json_array_get_object_element(packages, i);
                g_hash_table_insert(app.installed, g_strdup(string_field(object, "name")), g_strdup(string_field(object, "version")));
            }
            render();
            if (app.post_load_notice) {
                set_status(app.post_load_notice);
                g_clear_pointer(&app.post_load_notice, g_free);
            } else if (app.page == UPDATES || (app.page == SEARCH && app.query && *app.query)) run_query();
        } else if (operation == DETAIL_QUERY) {
            for (guint i = 0; i < json_array_get_length(packages); i++) {
                JsonObject *object = json_array_get_object_element(packages, i);
                if (!strcmp(string_field(object, "name"), app.package)) {
                    g_clear_pointer(&app.detail, json_object_unref);
                    app.detail = json_object_ref(object);
                    if (app.return_page != UPDATES)
                        g_hash_table_replace(app.details_cache, g_strdup(app.package), json_object_ref(object));
                    break;
                }
            }
            render();
            if (!app.detail) set_status("Package not found. Refresh Sources and try again.");
        } else {
            g_clear_pointer(&app.results, json_array_unref);
            app.results = json_array_ref(packages);
            render();
        }
    }
}

static void query_completed(GObject *source, GAsyncResult *result, gpointer unused) {
    (void)unused;
    g_autoptr(GError) error = NULL;
    g_autofree gchar *output = NULL, *errors = NULL;
    gboolean ok = g_subprocess_communicate_utf8_finish(G_SUBPROCESS(source), result, &output, &errors, &error);
    process_result(ok && g_subprocess_get_successful(G_SUBPROCESS(source)), output, error ? error->message : errors);
}

static void transaction_completed(GObject *source, GAsyncResult *result, gpointer unused) {
    (void)unused;
    g_autoptr(GError) error = NULL;
    gboolean ok = g_subprocess_wait_check_finish(G_SUBPROCESS(source), result, &error);
    /* Never approve a partial preview after a pipe read failure. */
    gboolean read_failed = GPOINTER_TO_INT(g_object_get_data(source, "read-failed"));
    g_autofree gchar *output = g_strdup(app.transaction_log->str);
    process_result(ok && !read_failed, output, error ? error->message : NULL);
}

static void transaction_line(GObject *source, GAsyncResult *result, gpointer unused) {
    (void)unused;
    g_autoptr(GError) error = NULL;
    gsize length = 0;
    g_autofree gchar *bytes = g_data_input_stream_read_line_finish(G_DATA_INPUT_STREAM(source), result, &length, &error);
    g_autofree gchar *line = bytes ? g_utf8_make_valid(bytes, (gssize)length) : NULL;
    if (!line) {
        if (error) {
            g_object_set_data(G_OBJECT(app.process), "read-failed", GINT_TO_POINTER(1));
            g_string_append(app.transaction_log, error->message);
        }
        g_subprocess_wait_check_async(app.process, NULL, transaction_completed, NULL);
        return;
    }
    g_string_append(app.transaction_log, line);
    g_string_append_c(app.transaction_log, '\n');
    /* A truncated solver preview is never eligible for confirmation. */
    if (app.transaction_log->len > 1024 * 1024) {
        g_object_set_data(G_OBJECT(app.process), "read-failed", GINT_TO_POINTER(1));
        gsize skip = app.transaction_log->len - LOG_LIMIT;
        while (skip < app.transaction_log->len && ((app.transaction_log->str[skip] & 0xc0) == 0x80)) skip++;
        g_string_erase(app.transaction_log, 0, (gssize)skip);
    }
    show_log(app.transaction_log->str, NULL);
    g_data_input_stream_read_line_async(app.stream, G_PRIORITY_DEFAULT, NULL, transaction_line, NULL);
}

static void execute(const gchar *const *argv, Operation operation, const gchar *status) {
    if (app.busy) return;
    gboolean stream = operation == REFRESH || operation == PLAN || operation == COMMIT;
    g_autoptr(GError) error = NULL;
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE |
        (stream ? G_SUBPROCESS_FLAGS_STDERR_MERGE : G_SUBPROCESS_FLAGS_STDERR_PIPE));
    g_subprocess_launcher_setenv(launcher, "LC_ALL", "C.UTF-8", TRUE);
    app.process = g_subprocess_launcher_spawnv(launcher, argv, &error);
    if (!app.process) { set_status(error->message); return; }
    app.operation = operation;
    set_busy(TRUE, status);
    if (stream) {
        g_string_set_size(app.transaction_log, 0);
        show_log("", NULL);
        app.stream = g_data_input_stream_new(g_subprocess_get_stdout_pipe(app.process));
        g_data_input_stream_read_line_async(app.stream, G_PRIORITY_DEFAULT, NULL, transaction_line, NULL);
    } else g_subprocess_communicate_utf8_async(app.process, NULL, NULL, query_completed, NULL);
}

static void load_installed(void) {
    const gchar *argv[] = {APK, "--no-network", "--repositories-file", "/dev/null", "query", "--from", "installed",
        "--format", "json", "--fields", "name,version,description", "--", "*", NULL};
    execute(argv, LOAD_INSTALLED, "Reading installed packages...");
}

static void run_query(void) {
    if (app.page == SEARCH && (!app.query || !*app.query)) { g_clear_pointer(&app.results, json_array_unref); render(); return; }
    g_autofree gchar *pattern = g_strdup_printf("*%s*", app.page == UPDATES ? "" : app.query);
    const gchar *argv[] = {APK, "--no-network", "query", "--format", "json", "--fields", "name,version,description",
        "--from", "system", "--match", "name", app.page == UPDATES ? "--upgradable" : "--available", "--", pattern, NULL};
    execute(argv, QUERY, app.page == UPDATES ? "Checking cached updates..." : "Searching packages...");
}

static void refresh_requested(GtkButton *button, gpointer unused) {
    (void)button; (void)unused;
    const gchar *argv[] = {APK, "--no-progress", "--timeout", "30", "--wait", "5", "update", NULL};
    execute(argv, REFRESH, "Refreshing sources...");
}

static gboolean closing(GtkWidget *widget, GdkEvent *event, gpointer unused) {
    (void)widget; (void)event; (void)unused;
    if (app.busy) { set_status("An APK operation is still running"); return TRUE; }
    if (!g_hash_table_size(app.queue)) return FALSE;
    GtkWidget *dialog = gtk_message_dialog_new(GTK_WINDOW(app.window), GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION,
        GTK_BUTTONS_NONE, "Discard the pending queue?");
    gtk_dialog_add_buttons(GTK_DIALOG(dialog), "Keep Queue", GTK_RESPONSE_CANCEL, "Discard", GTK_RESPONSE_ACCEPT, NULL);
    gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    return response != GTK_RESPONSE_ACCEPT;
}

static void activate(GtkApplication *application, gpointer unused) {
    (void)unused;
    if (app.window) { gtk_window_present(GTK_WINDOW(app.window)); return; }
    app.installed = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    app.details_cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)json_object_unref);
    app.queue = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    app.transaction_log = g_string_new(NULL);
    app.window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(app.window), "Packages");
    gtk_window_set_default_size(GTK_WINDOW(app.window), 360, 640);
    g_autoptr(GtkCssProvider) css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css,
        "window { background: #f7f8fa; color: #20252d; }"
        "headerbar { background: #f7f8fa; }"
        ".title { font-size: 21px; font-weight: bold; }"
        ".package-name { font-weight: bold; }"
        ".package-row { background: #ffffff; border: 0; border-bottom: 1px solid #e6e9ed; border-radius: 0; box-shadow: none; padding: 4px 8px; }"
        ".package-row:active { background: #eaf1f8; }"
        ".package-nav { background: #f7f8fa; border-top: 1px solid #dce0e6; }"
        ".package-nav button { padding: 8px 1px; border: 0; border-radius: 0; box-shadow: none; background: none; color: #5c6572; font-size: 10px; }"
        ".package-nav button:checked { color: #176cbd; background: #eaf1f8; }"
        ".dim-label { color: #667180; opacity: 1; text-shadow: none; }"
        "label:disabled { color: #8a929c; opacity: 1; text-shadow: none; }", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(app.window), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    app.header = gtk_header_bar_new();
    gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(app.header), TRUE);
    app.back = icon_button("go-previous-symbolic", "Back");
    app.refresh = icon_button("view-refresh-symbolic", "Refresh sources");
    app.queue_button = icon_button("view-list-symbolic", "Review queue");
    gtk_header_bar_pack_start(GTK_HEADER_BAR(app.header), app.back);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(app.header), app.refresh);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(app.header), app.queue_button);
    gtk_window_set_titlebar(GTK_WINDOW(app.window), app.header);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(app.window), box);
    app.scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(app.scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    app.body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(app.scroll), app.body);
    gtk_box_pack_start(GTK_BOX(box), app.scroll, TRUE, TRUE, 0);
    GtkWidget *status_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_container_set_border_width(GTK_CONTAINER(status_box), 8);
    app.spinner = gtk_spinner_new();
    app.status = label("Ready", "dim-label");
    gtk_box_pack_start(GTK_BOX(status_box), app.spinner, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(status_box), app.status, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(box), status_box, FALSE, FALSE, 0);
    GtkWidget *activity = gtk_expander_new("Activity");
    GtkWidget *log_scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_widget_set_size_request(log_scroll, -1, 120);
    app.log = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(app.log), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(app.log), GTK_WRAP_WORD_CHAR);
    gtk_container_add(GTK_CONTAINER(log_scroll), app.log);
    gtk_container_add(GTK_CONTAINER(activity), log_scroll);
    gtk_box_pack_start(GTK_BOX(box), activity, FALSE, FALSE, 0);
    app.nav = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_set_homogeneous(GTK_BOX(app.nav), TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(app.nav), "package-nav");
    const gchar *icons[] = {"go-home-symbolic", "network-server-symbolic", "software-update-available-symbolic", "object-select-symbolic", "system-search-symbolic"};
    const gchar *titles[] = {"Home", "Sources", "Updates", "Installed", "Search"};
    for (guint i = 0; i < 5; i++) {
        app.tabs[i] = gtk_toggle_button_new();
        GtkWidget *tab = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        gtk_box_pack_start(GTK_BOX(tab), gtk_image_new_from_icon_name(icons[i], GTK_ICON_SIZE_BUTTON), FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(tab), gtk_label_new(titles[i]), FALSE, FALSE, 0);
        gtk_container_add(GTK_CONTAINER(app.tabs[i]), tab);
        gtk_widget_set_tooltip_text(app.tabs[i], titles[i]);
        atk_object_set_name(gtk_widget_get_accessible(app.tabs[i]), titles[i]);
        g_signal_connect(app.tabs[i], "clicked", G_CALLBACK(tab_clicked), GINT_TO_POINTER(i));
        gtk_box_pack_start(GTK_BOX(app.nav), app.tabs[i], TRUE, TRUE, 0);
    }
    gtk_box_pack_end(GTK_BOX(box), app.nav, FALSE, FALSE, 0);
    g_signal_connect(app.back, "clicked", G_CALLBACK(back_clicked), NULL);
    g_signal_connect(app.queue_button, "clicked", G_CALLBACK(queue_clicked), NULL);
    g_signal_connect(app.refresh, "clicked", G_CALLBACK(refresh_requested), NULL);
    g_signal_connect(app.window, "delete-event", G_CALLBACK(closing), NULL);
    gtk_widget_show_all(app.window);
    g_autoptr(GError) error = NULL;
    g_autofree gchar *manifest = NULL;
    if (!g_file_get_contents(PLATFORM, &manifest, NULL, &error) || !(app.protected = parse_platform(manifest, &error))) {
        set_status(error->message);
        gtk_widget_set_sensitive(box, FALSE);
        gtk_widget_set_sensitive(app.header, FALSE);
        return;
    }
    if (geteuid() != 0) {
        set_status("Package transactions require the Pinecone root session.");
        gtk_widget_set_sensitive(box, FALSE);
        gtk_widget_set_sensitive(app.header, FALSE);
        return;
    }
    render();
    load_installed();
}

static void self_test(void) {
    const gchar *invalid[] = {"", "--force", "a/b", "a=b", "a@edge", "x;id", ".pinecone-platform", NULL};
    for (guint i = 0; invalid[i]; i++) g_assert_false(valid_package(invalid[i]));
    g_assert_true(valid_package("gtk+3.0-dev"));
    g_autoptr(GError) error = NULL;
    g_autoptr(GHashTable) pins = parse_platform("musl=1.2.6-r8\ngtk+3.0=3.24.52-r0\n", &error);
    g_assert_no_error(error);
    g_assert_true(g_hash_table_contains(pins, "musl"));
    g_assert_null(parse_platform("broken\n", &error)); g_clear_error(&error);
    g_assert_null(parse_platform("", &error)); g_clear_error(&error);
    g_assert_null(parse_packages("[{\"name\":\"--force\",\"version\":\"1\",\"description\":\"x\"}]", &error)); g_clear_error(&error);
    g_assert_null(parse_packages("[{\"name\":42}]", &error)); g_clear_error(&error);
    g_assert_null(parse_packages("{}", &error)); g_clear_error(&error);
    g_autoptr(JsonArray) packages = parse_packages("[{\"name\":\"htop\",\"version\":\"1-r0\",\"description\":\"Viewer\"}]", &error);
    g_assert_no_error(error);
    g_assert_cmpuint(json_array_get_length(packages), ==, 1);
    g_autoptr(JsonArray) virtuals = parse_packages("[{\"name\":\".pinecone-platform\",\"version\":\"1\",\"description\":\"Base\"}]", &error);
    g_assert_no_error(error);
    g_assert_cmpuint(json_array_get_length(virtuals), ==, 1);
    g_assert_true(valid_source("https://dl-cdn.alpinelinux.org/alpine/edge/main"));
    g_assert_true(valid_source("http://10.0.2.2/alpine/edge/community"));
    const gchar *bad_sources[] = {"file:///etc/passwd", "https://user:secret@example.org/x", "https://example.org/#x",
        "https://example.org/?x", "https:///", "https://example.org/\n--no-check-certificate", "@edge https://example.org", NULL};
    for (guint i = 0; bad_sources[i]; i++) g_assert_false(valid_source(bad_sources[i]));
    const gchar *sources = "# preserved comment\nhttp://10.0.2.2/alpine/edge/main\n@tag https://example.org/repo\n";
    g_autofree gchar *disabled = toggled_source(sources, 1);
    g_assert_nonnull(strstr(disabled, DISABLED_SOURCE "http://10.0.2.2"));
    g_autofree gchar *enabled = toggled_source(disabled, 1);
    g_assert_cmpstr(enabled, ==, sources);
    g_assert_null(toggled_source(sources, 0));
    g_assert_null(toggled_source(sources, 2));
    g_assert_null(toggled_source(sources, 100));
    g_autoptr(GFileIOStream) io = NULL;
    g_autoptr(GFile) temporary = g_file_new_tmp("pinecone-source-test-XXXXXX", &io, &error);
    g_assert_no_error(error);
    g_assert_true(g_io_stream_close(G_IO_STREAM(io), NULL, &error));
    g_autofree gchar *etag = NULL;
    g_assert_true(g_file_replace_contents(temporary, sources, strlen(sources), NULL, FALSE,
        G_FILE_CREATE_PRIVATE, &etag, NULL, &error));
    g_assert_true(replace_sources(temporary, disabled, etag, &error));
    g_assert_false(replace_sources(temporary, "must not overwrite", etag, &error));
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_WRONG_ETAG); g_clear_error(&error);
    g_autofree gchar *actual = NULL;
    g_assert_true(g_file_load_contents(temporary, NULL, &actual, NULL, NULL, &error));
    g_assert_cmpstr(actual, ==, disabled);
    g_autofree gchar *path = g_file_get_path(temporary);
    g_autofree gchar *backup = g_strconcat(path, "~", NULL);
    g_assert_true(g_file_delete(temporary, NULL, &error));
    g_assert_cmpint(unlink(backup), ==, 0);
    app.protected = g_hash_table_ref(pins);
    app.queue = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_assert_false(queue_change("musl", REMOVE_PACKAGE, &error)); g_clear_error(&error);
    g_assert_false(queue_change("musl", UPDATE_PACKAGE, &error)); g_clear_error(&error);
    g_assert_false(queue_change("--force", INSTALL_PACKAGE, &error)); g_clear_error(&error);
    g_assert_true(queue_change("tree", INSTALL_PACKAGE, &error));
    g_assert_true(queue_change("htop", INSTALL_PACKAGE, &error));
    g_assert_true(queue_change("htop", INSTALL_PACKAGE, &error));
    g_assert_cmpuint(g_hash_table_size(app.queue), ==, 2);
    g_assert_false(queue_change("nano", REMOVE_PACKAGE, &error)); g_clear_error(&error);
    g_autoptr(GPtrArray) args = transaction_argv(PLAN);
    g_assert_cmpstr(g_ptr_array_index(args, 6), ==, "add");
    g_assert_cmpstr(g_ptr_array_index(args, 7), ==, "--simulate");
    g_assert_cmpstr(g_ptr_array_index(args, 8), ==, "--");
    g_assert_cmpstr(g_ptr_array_index(args, 9), ==, "htop");
    g_assert_cmpstr(g_ptr_array_index(args, 10), ==, "tree");
    g_assert_null(g_ptr_array_index(args, 11));
    g_hash_table_remove_all(app.queue);
    g_assert_true(queue_change("nano", UPDATE_PACKAGE, &error));
    g_autoptr(GPtrArray) updates = transaction_argv(COMMIT);
    g_assert_cmpstr(g_ptr_array_index(updates, 7), ==, "--no-interactive");
    g_assert_cmpstr(g_ptr_array_index(updates, 8), ==, "--upgrade");
    g_hash_table_remove_all(app.queue);
    g_assert_true(queue_change("tree", REMOVE_PACKAGE, &error));
    g_autoptr(GPtrArray) removals = transaction_argv(COMMIT);
    g_assert_cmpstr(g_ptr_array_index(removals, 6), ==, "del");
    g_assert_cmpstr(g_ptr_array_index(removals, 8), ==, "--");
    g_assert_cmpstr(g_ptr_array_index(removals, 9), ==, "tree");
    g_clear_pointer(&app.queue, g_hash_table_unref);
    g_clear_pointer(&app.protected, g_hash_table_unref);
    g_print("Package metadata, source validation, protected base and transaction queue tests passed.\n");
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--self-test")) { self_test(); return 0; }
    g_autoptr(GtkApplication) application = gtk_application_new("me.gmoran.pinecone.packages", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    int result = g_application_run(G_APPLICATION(application), argc, argv);
    g_clear_pointer(&app.installed, g_hash_table_unref);
    g_clear_pointer(&app.details_cache, g_hash_table_unref);
    g_clear_pointer(&app.protected, g_hash_table_unref);
    g_clear_pointer(&app.queue, g_hash_table_unref);
    g_clear_pointer(&app.installed_records, json_array_unref);
    g_clear_pointer(&app.results, json_array_unref);
    g_clear_pointer(&app.detail, json_object_unref);
    if (app.transaction_log) g_string_free(app.transaction_log, TRUE);
    g_free(app.package); g_free(app.query); g_free(app.source_contents); g_free(app.source_etag); g_free(app.post_load_notice);
    return result;
}
