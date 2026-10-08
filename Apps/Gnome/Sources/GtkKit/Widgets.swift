public import CGtk

/// The pointer type GTK widget functions take and return.
public typealias Widget = UnsafeMutablePointer<GtkWidget>

extension UnsafeMutablePointer where Pointee == GtkWidget {
    /// For GTK 4 functions whose widget type is opaque in Swift (GtkLabel,
    /// GtkButton, GtkBox, …), which take `OpaquePointer`.
    @inlinable public var opaque: OpaquePointer { OpaquePointer(self) }

    /// For GTK functions whose widget type is defined in Swift (GtkBox,
    /// GtkButton, GtkEntry, GtkWindow, …). Only valid if the widget really is
    /// that type (or a subclass), like the C cast macros.
    @inlinable public func `as`<T>(_ type: T.Type) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(self).assumingMemoryBound(to: T.self)
    }
}

@MainActor
public enum UI {
    public static func addClasses(_ widget: Widget, _ classes: [String]) {
        for name in classes { gtk_widget_add_css_class(widget, name) }
    }

    public static func label(_ text: String, classes: [String] = [], wrap: Bool = false, xalign: Float = 0) -> Widget {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(label.opaque, xalign)
        if wrap {
            gtk_label_set_wrap(label.opaque, 1)
            gtk_label_set_wrap_mode(label.opaque, PANGO_WRAP_WORD_CHAR)
        }
        addClasses(label, classes)
        return label
    }

    public static func setMarkup(_ label: Widget, _ markup: String) {
        gtk_label_set_markup(label.opaque, markup)
    }

    public static func setText(_ label: Widget, _ text: String) {
        if String(cString: gtk_label_get_text(label.opaque)) != text { gtk_label_set_text(label.opaque, text) }
    }

    public static func box(_ orientation: GtkOrientation, spacing: Int32 = 0, classes: [String] = [], _ children: [Widget] = []) -> Widget {
        let box = gtk_box_new(orientation, spacing)!
        for child in children { gtk_box_append(box.as(GtkBox.self), child) }
        addClasses(box, classes)
        return box
    }

    public static func vbox(spacing: Int32 = 0, classes: [String] = [], _ children: [Widget] = []) -> Widget {
        box(GTK_ORIENTATION_VERTICAL, spacing: spacing, classes: classes, children)
    }

    public static func hbox(spacing: Int32 = 0, classes: [String] = [], _ children: [Widget] = []) -> Widget {
        box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing, classes: classes, children)
    }

    public static func append(_ box: Widget, _ child: Widget) {
        gtk_box_append(box.as(GtkBox.self), child)
    }

    public static func removeAllChildren(_ box: Widget) {
        while let child = gtk_widget_get_first_child(box) { gtk_box_remove(box.as(GtkBox.self), child) }
    }

    public static func button(_ label: String? = nil, icon: String? = nil, classes: [String] = [], tooltip: String? = nil,
                              _ action: @escaping @MainActor () -> Void) -> Widget {
        let button: Widget = icon.flatMap { gtk_button_new_from_icon_name($0) } ?? gtk_button_new_with_label(label ?? "")!
        if icon != nil, let label { gtk_button_set_label(button.as(GtkButton.self), label) }
        if let tooltip { gtk_widget_set_tooltip_text(button, tooltip) }
        addClasses(button, classes)
        connect(button, "clicked", action)
        return button
    }

    public static func setSensitive(_ widget: Widget, _ sensitive: Bool) {
        gtk_widget_set_sensitive(widget, sensitive ? 1 : 0)
    }

    public static func setVisible(_ widget: Widget, _ visible: Bool) {
        gtk_widget_set_visible(widget, visible ? 1 : 0)
    }

    public static func setMargins(_ widget: Widget, _ margin: Int32) {
        gtk_widget_set_margin_top(widget, margin)
        gtk_widget_set_margin_bottom(widget, margin)
        gtk_widget_set_margin_start(widget, margin)
        gtk_widget_set_margin_end(widget, margin)
    }

    public static func expand(_ widget: Widget, horizontal: Bool = true, vertical: Bool = false) {
        gtk_widget_set_hexpand(widget, horizontal ? 1 : 0)
        gtk_widget_set_vexpand(widget, vertical ? 1 : 0)
    }

    public static func scrolled(_ child: Widget) -> Widget {
        let scrolled = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(scrolled.opaque, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scrolled.opaque, child)
        expand(scrolled, vertical: true)
        return scrolled
    }

    /// Libadwaita's centered, width-limited content area.
    public static func clamp(_ child: Widget, maximumWidth: Int32 = 640) -> Widget {
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(clamp.opaque, maximumWidth)
        adw_clamp_set_child(clamp.opaque, child)
        return clamp
    }

    public static func entry(placeholder: String) -> Widget {
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(entry.as(GtkEntry.self), placeholder)
        return entry
    }

    /// The editable's text (GtkEntry, GtkText…).
    public static func text(of editable: Widget) -> String {
        String(cString: gtk_editable_get_text(editable.opaque))
    }

    /// Sets the text only if it differs, so typing isn't disturbed by renders.
    public static func setText(ofEditable editable: Widget, _ text: String) {
        if UI.text(of: editable) != text { gtk_editable_set_text(editable.opaque, text) }
    }

    public static func image(icon: String, pixelSize: Int32 = 16) -> Widget {
        let image = gtk_image_new_from_icon_name(icon)!
        gtk_image_set_pixel_size(image.opaque, pixelSize)
        return image
    }
}
