import streamlit as st


def setup_page(title: str, icon: str = "🌐", layout: str = "wide") -> None:
    """Set consistent page config across all pages."""
    st.set_page_config(page_title=title, page_icon=icon, layout=layout)


def hide_streamlit_chrome() -> None:
    """Hide Streamlit main menu and footer."""
    html = """
	    <style>
	        #MainMenu {visibility: hidden;}
	        footer{ visibility: hidden;}
	    </style>
	"""
    st.markdown(html, unsafe_allow_html=True)


def render_header(title: str, subtitle: str | None = None) -> None:
    """Render a standard page header."""
    st.markdown(f"# {title}")
    if subtitle:
        st.markdown(subtitle)