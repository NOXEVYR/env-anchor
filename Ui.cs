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
            int d = radius * 2;
            var p = new GraphicsPath();
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right-d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom-d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
        public static void Card(Graphics g, Rectangle r, Color fill)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using(var path=Round(r,14)) using(var brush=new SolidBrush(fill)) g.FillPath(brush,path);
        }
    }
    public class RoundedButton : Button
    {
        private bool hovered;
        public RoundedButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle=FlatStyle.Flat; FlatAppearance.BorderSize=0;
        }
        protected override void OnMouseEnter(EventArgs e) {hovered=true; Invalidate(); base.OnMouseEnter(e);}
        protected override void OnMouseLeave(EventArgs e) {hovered=false; Invalidate(); base.OnMouseLeave(e);}
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            Color fill=hovered && Enabled ? FlatAppearance.MouseOverBackColor : BackColor;
            if(fill==Color.Empty) fill=BackColor;
            using(var p=Shapes.Round(new Rectangle(1,1,Width-3,Height-3),8))
            {
                using(var brush=new SolidBrush(fill)) e.Graphics.FillPath(brush,p);
                if(FlatAppearance.BorderSize>0) using(var pen=new Pen(FlatAppearance.BorderColor)) e.Graphics.DrawPath(pen,p);
                if(Focused) using(var pen=new Pen(Color.FromArgb(68,167,151),2)) e.Graphics.DrawPath(pen,p);
            }
            TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Enabled?ForeColor:SystemColors.GrayText,
                TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine);
        }
    }
}
