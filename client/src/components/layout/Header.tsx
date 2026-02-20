import React from 'react';
import { useNavigate } from 'react-router-dom';
import { Menu, X } from 'lucide-react';

export const Header = () => {
    const navigate = useNavigate();
    const [mobileMenuOpen, setMobileMenuOpen] = React.useState(false);

    return (
        <nav className="landing-nav">
            <div className="nav-content">
                <div className="nav-logo" onClick={() => navigate('/')}>
                    <span className="logo-text">vibe</span>
                </div>

                <div className="nav-center">
                    <div className={`nav-links ${mobileMenuOpen ? 'open' : ''}`}>
                        <a href="#features" onClick={() => setMobileMenuOpen(false)}>Features</a>
                        <a href="#network" onClick={() => setMobileMenuOpen(false)}>Network</a>
                        <a href="#security" onClick={() => setMobileMenuOpen(false)}>Security</a>
                    </div>
                </div>

                <div className="nav-actions">
                    <button className="btn-text" onClick={() => navigate('/app')}>Sign In</button>
                    <button className="btn-primary" onClick={() => navigate('/app')}>Join</button>

                    <div className="mobile-toggle" onClick={() => setMobileMenuOpen(!mobileMenuOpen)}>
                        {mobileMenuOpen ? <X size={20} /> : <Menu size={20} />}
                    </div>
                </div>
            </div>
        </nav>
    );
};
