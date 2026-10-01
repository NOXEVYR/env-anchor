using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EnvAnchorUi
{
    public static class Shapes
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            if (r.Width <= 0 || r.Height <= 0) return p;
            radius = Math.Max(0, Math.Min(radius, Math.Min(r.Width, r.Height) / 2));
            if (radius == 0) { p.AddRectangle(r); return p; }
            int d = radius * 2;
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right-d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom-d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
        public static void Card(Graphics g, Rectangle r, Color fill)
        {
            if (r.Width <= 0 || r.Height <= 0) return;
            SmoothingMode previous = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using(var path=Round(r,14)) using(var brush=new SolidBrush(fill)) g.FillPath(brush,path);
            g.SmoothingMode = previous;
        }
    }
    public class RoundedButton : Button
    {
        private bool hovered;
        private bool mousePressed;
        private bool keyboardPressed;
        private bool defaultButton;
        private string iconKind = String.Empty;

        public string IconKind
        {
            get { return iconKind; }
            set { iconKind = (value ?? String.Empty).Trim().ToLowerInvariant(); Invalidate(); }
        }

        public RoundedButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle=FlatStyle.Flat; FlatAppearance.BorderSize=0;
            Padding = new Padding(12, 0, 12, 0);
        }
        protected override void OnMouseEnter(EventArgs e) {hovered=true; Invalidate(); base.OnMouseEnter(e);}
        protected override void OnMouseLeave(EventArgs e) {hovered=false; Invalidate(); base.OnMouseLeave(e);}
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && Enabled) mousePressed = true;
            base.OnMouseDown(e); Invalidate();
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool inside = ClientRectangle.Contains(e.Location);
            if (hovered != inside) { hovered = inside; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseUp(MouseEventArgs e)
        {
            mousePressed = false; base.OnMouseUp(e); Invalidate();
        }
        protected override void OnMouseCaptureChanged(EventArgs e)
        {
            if (!Capture) mousePressed = false;
            base.OnMouseCaptureChanged(e); Invalidate();
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space && Enabled) keyboardPressed = true;
            base.OnKeyDown(e); Invalidate();
        }
        protected override void OnKeyUp(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space) keyboardPressed = false;
            base.OnKeyUp(e); Invalidate();
        }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e)
        {
            mousePressed = false; keyboardPressed = false;
            base.OnLostFocus(e); Invalidate();
        }
        protected override void OnEnabledChanged(EventArgs e)
        {
            if (!Enabled) { mousePressed = false; keyboardPressed = false; hovered = false; }
            base.OnEnabledChanged(e); Invalidate();
        }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void OnForeColorChanged(EventArgs e) { base.OnForeColorChanged(e); Invalidate(); }
        public override void NotifyDefault(bool value)
        {
            defaultButton = value; base.NotifyDefault(value); Invalidate();
        }

        private static Color Blend(Color source, Color target, float amount)
        {
            return Color.FromArgb(source.A,
                (int)(source.R + (target.R - source.R) * amount),
                (int)(source.G + (target.G - source.G) * amount),
                (int)(source.B + (target.B - source.B) * amount));
        }

        private bool HasIcon
        {
            get { return iconKind == "add" || iconKind == "folder" || iconKind == "open" ||
                         iconKind == "arrow" || iconKind == "link" || iconKind == "undo"; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (Width < 4 || Height < 4) return;
            e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            bool pressed = Enabled && ((mousePressed && hovered) || keyboardPressed);
            Color fill = BackColor;
            if (hovered && Enabled)
                fill = FlatAppearance.MouseOverBackColor.IsEmpty ? Blend(BackColor, Color.Black, .06f) : FlatAppearance.MouseOverBackColor;
            if (pressed)
                fill = FlatAppearance.MouseDownBackColor.IsEmpty ? Blend(fill, Color.Black, .10f) : FlatAppearance.MouseDownBackColor;
            if (!Enabled) fill = Blend(BackColor, Color.FromArgb(234, 239, 241), .75f);
            Color ink = Enabled ? ForeColor : Color.FromArgb(137, 149, 153);
            using(var p=Shapes.Round(new Rectangle(1,1,Width-3,Height-3),8))
            {
                using(var brush=new SolidBrush(fill)) e.Graphics.FillPath(brush,p);
                if(FlatAppearance.BorderSize>0)
                    using(var pen=new Pen(Enabled ? FlatAppearance.BorderColor : Color.FromArgb(216, 225, 228), Math.Min(FlatAppearance.BorderSize, 2)))
                        e.Graphics.DrawPath(pen,p);
                if(defaultButton && Enabled && !Focused)
                    using(var pen=new Pen(Color.FromArgb(99, 162, 153))) e.Graphics.DrawPath(pen,p);
            }
            if (Focused && Enabled && Width > 10 && Height > 10)
            {
                Color focus = fill.GetBrightness() < .5f ? Color.FromArgb(213, 241, 235) : Color.FromArgb(22, 125, 112);
                using (var path = Shapes.Round(new Rectangle(4, 4, Width - 9, Height - 9), 5))
                using (var pen = new Pen(focus)) { pen.DashStyle = DashStyle.Dot; e.Graphics.DrawPath(pen, path); }
            }

            Rectangle content = new Rectangle(Padding.Left + 3, Padding.Top + 3,
                Math.Max(0, Width - Padding.Horizontal - 6), Math.Max(0, Height - Padding.Vertical - 6));
            if (content.Width == 0 || content.Height == 0) return;
            if (pressed) content.Offset(0, 1);
            TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding;
            if (!UseMnemonic) flags |= TextFormatFlags.NoPrefix;
            else if (!ShowKeyboardCues) flags |= TextFormatFlags.HidePrefix;

            if (HasIcon && content.Width >= 18)
            {
                int iconSize = Math.Min(16, content.Height);
                int gap = String.IsNullOrEmpty(Text) ? 0 : 7;
                gap = Math.Min(gap, Math.Max(0, content.Width - iconSize));
                int textWidth = Math.Min(Math.Max(0, content.Width - iconSize - gap),
                    TextRenderer.MeasureText(e.Graphics, Text, Font, new Size(Int32.MaxValue, content.Height), flags).Width);
                int groupWidth = iconSize + gap + textWidth;
                int start = content.Left + (content.Width - groupWidth) / 2;
                DrawIcon(e.Graphics, new Rectangle(start, content.Top + (content.Height - iconSize) / 2, iconSize, iconSize), ink);
                Rectangle textBounds = new Rectangle(start + iconSize + gap, content.Top, textWidth, content.Height);
                if (textBounds.Width > 0) TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, ink, flags);
            }
            else
                TextRenderer.DrawText(e.Graphics,Text,Font,content,ink,flags | TextFormatFlags.HorizontalCenter);
        }

        private void DrawIcon(Graphics g, Rectangle bounds, Color color)
        {
            if (bounds.Width < 8 || bounds.Height < 8) return;
            GraphicsState state = g.Save();
            g.TranslateTransform(bounds.Left, bounds.Top);
            g.ScaleTransform(bounds.Width / 16f, bounds.Height / 16f);
            using (var pen = new Pen(color, 1.5f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                if (iconKind == "add")
                {
                    g.DrawLine(pen, 8, 3, 8, 13); g.DrawLine(pen, 3, 8, 13, 8);
                }
                else if (iconKind == "folder")
                    g.DrawPolygon(pen, new PointF[] { new PointF(2, 4), new PointF(6, 4), new PointF(8, 6), new PointF(14, 6), new PointF(14, 13), new PointF(2, 13) });
                else if (iconKind == "open")
                {
                    g.DrawLines(pen, new PointF[] { new PointF(7, 3), new PointF(3, 3), new PointF(3, 13), new PointF(13, 13), new PointF(13, 9) });
                    g.DrawLine(pen, 7, 9, 13, 3); g.DrawLine(pen, 9, 3, 13, 3); g.DrawLine(pen, 13, 3, 13, 7);
                }
                else if (iconKind == "arrow")
                {
                    g.DrawLine(pen, 2, 8, 14, 8); g.DrawLine(pen, 9, 3, 14, 8); g.DrawLine(pen, 9, 13, 14, 8);
                }
                else if (iconKind == "link")
                {
                    g.DrawArc(pen, 1, 5, 9, 6, 90, 180); g.DrawArc(pen, 6, 5, 9, 6, 270, 180);
                    g.DrawLine(pen, 5, 8, 11, 8);
                }
                else if (iconKind == "undo")
                {
                    g.DrawArc(pen, 3, 4, 10, 9, 205, 285);
                    g.DrawLine(pen, 3, 3, 3, 7); g.DrawLine(pen, 3, 7, 7, 7);
                }
            }
            g.Restore(state);
        }
    }

    public class DashboardForm : Form
    {
        private Rectangle locationCardBounds;
        private Rectangle contentCardBounds;
        private Rectangle settingsCardBounds;
        private Rectangle statusCardBounds;
        private int sidebarWidth = 180;

        public Rectangle LocationCardBounds { get { return locationCardBounds; } set { locationCardBounds = value; Invalidate(); } }
        public Rectangle ContentCardBounds { get { return contentCardBounds; } set { contentCardBounds = value; Invalidate(); } }
        public Rectangle SettingsCardBounds { get { return settingsCardBounds; } set { settingsCardBounds = value; Invalidate(); } }
        public Rectangle StatusCardBounds { get { return statusCardBounds; } set { statusCardBounds = value; Invalidate(); } }
        public int SidebarWidth { get { return sidebarWidth; } set { sidebarWidth = Math.Max(0, value); Invalidate(); } }

        public DashboardForm()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(244, 247, 248);
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.FromArgb(244, 247, 248));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            int width = Math.Min(sidebarWidth, ClientSize.Width);
            if (width > 0)
            {
                using (var brush = new SolidBrush(Color.FromArgb(238, 244, 243)))
                    e.Graphics.FillRectangle(brush, 0, 0, width, ClientSize.Height);
                using (var pen = new Pen(Color.FromArgb(221, 231, 234)))
                    e.Graphics.DrawLine(pen, width - 1, 0, width - 1, ClientSize.Height);
            }
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            DrawCard(e.Graphics, locationCardBounds);
            DrawCard(e.Graphics, contentCardBounds);
            DrawCard(e.Graphics, settingsCardBounds);
            DrawCard(e.Graphics, statusCardBounds);
        }

        private static void DrawCard(Graphics g, Rectangle bounds)
        {
            if (bounds.Width < 2 || bounds.Height < 2) return;
            Rectangle edge = new Rectangle(bounds.Left, bounds.Top, bounds.Width - 1, bounds.Height - 1);
            using (var path = Shapes.Round(edge, 14))
            using (var brush = new SolidBrush(Color.White))
            using (var pen = new Pen(Color.FromArgb(224, 232, 235)))
            {
                g.FillPath(brush, path); g.DrawPath(pen, path);
            }
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); Invalidate(); }
    }

    // Only the header is custom painted; native rows retain checkboxes and selection behavior.
    public class AnchorListView : ListView
    {
        public AnchorListView()
        {
            DoubleBuffered = true;
            OwnerDraw = true;
        }

        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            e.DrawDefault = true; base.OnDrawItem(e);
        }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            e.DrawDefault = true; base.OnDrawSubItem(e);
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            using (var brush = new SolidBrush(Color.FromArgb(245, 248, 249))) e.Graphics.FillRectangle(brush, e.Bounds);
            using (var pen = new Pen(Color.FromArgb(226, 233, 236)))
            {
                e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                e.Graphics.DrawLine(pen, e.Bounds.Right - 1, e.Bounds.Top + 7, e.Bounds.Right - 1, e.Bounds.Bottom - 7);
            }
            Rectangle textBounds = Rectangle.Inflate(e.Bounds, -10, 0);
            if (textBounds.Width > 0)
            {
                TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
                    TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
                if (e.Header.TextAlign == HorizontalAlignment.Center) flags |= TextFormatFlags.HorizontalCenter;
                else if (e.Header.TextAlign == HorizontalAlignment.Right) flags |= TextFormatFlags.Right;
                TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, textBounds, Color.FromArgb(95, 115, 122), flags);
            }
            base.OnDrawColumnHeader(e);
        }
    }
}
