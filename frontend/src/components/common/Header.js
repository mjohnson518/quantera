import React from 'react';
import { Link, NavLink } from 'react-router-dom';
import { FaWallet, FaSun, FaMoon } from 'react-icons/fa';
import { useTheme } from '../../contexts/ThemeContext';
import { 
  AppBar,
  Toolbar,
  Typography,
  Button,
  Container,
  Box,
  IconButton,
  useMediaQuery,
  Drawer,
  List,
  ListItem,
  ListItemText
} from '@mui/material';
import { useTheme as useMuiTheme } from '@mui/material/styles';
import MenuIcon from '@mui/icons-material/Menu';

const Header = () => {
  const { theme, toggleTheme } = useTheme();
  const muiTheme = useMuiTheme();
  const isMobile = useMediaQuery(muiTheme.breakpoints.down('md'));
  const [drawerOpen, setDrawerOpen] = React.useState(false);

  const toggleDrawer = () => {
    setDrawerOpen(!drawerOpen);
  };

  const navItems = [
    { title: 'Home', path: '/' },
    { title: 'Marketplace', path: '/marketplace' },
    { title: 'Portfolio', path: '/portfolio' }
  ];

  const drawer = (
    <Box onClick={toggleDrawer} sx={{ textAlign: 'center' }}>
      <Typography variant="h6" sx={{ my: 2 }}>
        <span style={{ color: muiTheme.palette.primary.main }}>Q</span>uantera Platform
      </Typography>
      <List>
        {navItems.map((item) => (
          <ListItem key={item.title} component={NavLink} to={item.path} sx={{
            color: 'text.primary',
            textDecoration: 'none',
            '&.active': {
              color: 'primary.main',
              fontWeight: 'bold'
            }
          }}>
            <ListItemText primary={item.title} />
          </ListItem>
        ))}
      </List>
    </Box>
  );

  return (
    <AppBar 
      position="static" 
      sx={{ 
        backgroundColor: 'var(--navbar-bg)',
        color: 'var(--navbar-text)'
      }}
      elevation={1}
    >
      <Container>
        <Toolbar disableGutters>
          <Typography
            variant="h6"
            component={Link}
            to="/"
            sx={{
              mr: 2,
              display: { xs: 'none', md: 'flex' },
              fontWeight: 700,
              color: 'var(--navbar-text)',
              textDecoration: 'none',
            }}
          >
            <span style={{ color: muiTheme.palette.primary.light }}>Q</span>uantera Platform
          </Typography>

          {isMobile ? (
            <>
              <IconButton
                sx={{ mr: 2, display: { md: 'none' }, color: 'var(--navbar-text)' }}
                aria-label="open drawer"
                edge="start"
                onClick={toggleDrawer}
              >
                <MenuIcon />
              </IconButton>
              <Typography
                variant="h6"
                component={Link}
                to="/"
                sx={{
                  flexGrow: 1,
                  display: { xs: 'flex', md: 'none' },
                  fontWeight: 700,
                  color: 'var(--navbar-text)',
                  textDecoration: 'none',
                }}
              >
                <span style={{ color: muiTheme.palette.primary.light }}>Q</span>uantera
              </Typography>
              <Drawer
                anchor="left"
                open={drawerOpen}
                onClose={toggleDrawer}
              >
                {drawer}
              </Drawer>
            </>
          ) : (
            <Box sx={{ flexGrow: 1, display: 'flex' }}>
              {navItems.map((item) => (
                <Button
                  key={item.title}
                  component={NavLink}
                  to={item.path}
                  sx={{
                    color: 'var(--navbar-text)',
                    display: 'block',
                    mx: 1,
                    '&.active': {
                      color: muiTheme.palette.primary.light,
                      fontWeight: 'bold'
                    }
                  }}
                >
                  {item.title}
                </Button>
              ))}
            </Box>
          )}

          <Box sx={{ display: 'flex', alignItems: 'center' }}>
            <Box 
              onClick={toggleTheme} 
              sx={{
                position: 'relative',
                width: '50px',
                height: '26px',
                mr: 2,
                borderRadius: '20px',
                backgroundColor: 'var(--primary-color)',
                cursor: 'pointer',
                transition: 'background-color 0.3s ease',
                display: 'flex',
                alignItems: 'center',
                padding: '0 4px',
              }}
              aria-label="Toggle theme"
              role="button"
              tabIndex={0}
            >
              <Box sx={{
                width: '20px',
                height: '20px',
                borderRadius: '50%',
                backgroundColor: '#fff',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                transition: 'transform 0.3s ease',
                transform: theme === 'light' ? 'translateX(0)' : 'translateX(24px)',
                color: theme === 'light' ? '#f59e0b' : '#1e40af',
              }}>
                {theme === 'light' ? <FaSun size={12} /> : <FaMoon size={12} />}
              </Box>
            </Box>
            <Button 
              variant="outlined" 
              sx={{
                color: 'var(--navbar-text)',
                borderColor: 'var(--navbar-text)',
                '&:hover': {
                  borderColor: muiTheme.palette.primary.light,
                  backgroundColor: 'rgba(255, 255, 255, 0.08)',
                }
              }}
              startIcon={<FaWallet />}
            >
              Connect Wallet
            </Button>
          </Box>
        </Toolbar>
      </Container>
    </AppBar>
  );
};

export default Header; 