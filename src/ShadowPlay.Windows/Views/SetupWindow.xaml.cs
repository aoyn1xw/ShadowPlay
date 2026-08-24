using System.Windows;
using ShadowPlay.Windows.Services;
using ShadowPlay.Windows.ViewModels;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;

namespace ShadowPlay.Windows.Views;

public partial class SetupWindow : Window
{
    private readonly AppController _controller;

    public SetupWindow(AppController controller, SetupViewModel viewModel)
    {
        InitializeComponent();
        _controller = controller;
        DataContext = viewModel;
    }

    public SetupViewModel ViewModel => (SetupViewModel)DataContext;

    private async void OnConfirmClick(object sender, RoutedEventArgs e)
    {
        var vm = ViewModel;
        var saved = await _controller.SelectFolderAsync(vm.FolderPath);
        if (!saved)
        {
            // Controller already recorded an error status; show it inline too.
            MessageBox.Show(
                _controller.Status.Detail ?? "That folder could not be used.",
                "ShadowPlay",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        DialogResult = true;
    }
}
